# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "pyulog",
#     "pyyaml",
#     "matplotlib",
#     "numpy",
#     "scipy",
# ]
# ///

import argparse
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import pyulog
import yaml
from matplotlib import pyplot as plt
from scipy import signal
from scipy.optimize import least_squares


@dataclass
class FitResult:
    order: int
    theta: np.ndarray
    y_hat: np.ndarray
    poles: np.ndarray
    stable: bool
    fit_pct: float
    mse_val: float
    success: bool
    message: str
    gain: float
    delay_sec: float
    freq_response: dict[str, Any] | None


def load_config(config_path: str) -> dict:
    with open(config_path, "r") as f:
        return yaml.safe_load(f)


def parse_args():
    parser = argparse.ArgumentParser(description="Rate model identification from ULog")
    parser.add_argument("--config", type=str, default="config_rate_identification.yaml")
    parser.add_argument("--ulg", type=str, action="append", default=None)
    parser.add_argument("--no-plot", action="store_true")
    return parser.parse_args()


def get_topic_data(ulog: pyulog.ULog, topic_name: str):
    for d in ulog.data_list:
        if d.name == topic_name:
            return d
    return None


def resample_signal(
    ts_orig: np.ndarray, values_orig: np.ndarray, ts_target: np.ndarray
) -> np.ndarray:
    return np.interp(ts_target, ts_orig, values_orig)


def detect_maneuver_segments(
    ts: np.ndarray,
    u: np.ndarray,
    threshold: float,
    min_duration_s: float,
    padding_samples: int,
) -> list[tuple[int, int]]:
    active = np.abs(u) > threshold
    segments: list[tuple[int, int]] = []
    start = None
    for i, is_active in enumerate(active):
        if is_active and start is None:
            start = i
        elif not is_active and start is not None:
            if ts[i - 1] - ts[start] >= min_duration_s:
                segments.append((start, i - 1))
            start = None
    if start is not None and ts[-1] - ts[start] >= min_duration_s:
        segments.append((start, len(ts) - 1))

    padded: list[tuple[int, int]] = []
    for start_idx, end_idx in segments:
        padded.append(
            (
                max(0, start_idx - padding_samples),
                min(len(ts) - 1, end_idx + padding_samples),
            )
        )

    merged: list[tuple[int, int]] = []
    for start_idx, end_idx in padded:
        if merged and start_idx <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end_idx))
        else:
            merged.append((start_idx, end_idx))
    return merged


def extract_segment(
    ts: np.ndarray, u: np.ndarray, y: np.ndarray, segment: tuple[int, int]
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    start_idx, end_idx = segment
    return (
        ts[start_idx : end_idx + 1],
        u[start_idx : end_idx + 1],
        y[start_idx : end_idx + 1],
    )


def simulate_oe_first_order(u: np.ndarray, theta: np.ndarray) -> np.ndarray:
    a1, b1 = theta
    y_hat = np.zeros(len(u), dtype=float)
    for k in range(1, len(u)):
        y_hat[k] = -a1 * y_hat[k - 1] + b1 * u[k - 1]
    return y_hat


def simulate_oe_second_order(u: np.ndarray, theta: np.ndarray) -> np.ndarray:
    a1, a2, b1, b2 = theta
    y_hat = np.zeros(len(u), dtype=float)
    for k in range(2, len(u)):
        y_hat[k] = (
            -a1 * y_hat[k - 1] - a2 * y_hat[k - 2] + b1 * u[k - 1] + b2 * u[k - 2]
        )
    return y_hat


def residual_first_order(theta: np.ndarray, u: np.ndarray, y: np.ndarray) -> np.ndarray:
    return simulate_oe_first_order(u, theta) - y


def residual_second_order(
    theta: np.ndarray, u: np.ndarray, y: np.ndarray
) -> np.ndarray:
    return simulate_oe_second_order(u, theta) - y


def poles_first_order(theta: np.ndarray) -> np.ndarray:
    return np.array([-theta[0]])


def poles_second_order(theta: np.ndarray) -> np.ndarray:
    return np.roots([1.0, theta[0], theta[1]])


def is_stable(poles: np.ndarray) -> bool:
    return bool(np.all(np.abs(poles) < 1.0))


def fit_percent(y: np.ndarray, y_hat: np.ndarray) -> float:
    num = np.linalg.norm(y - y_hat)
    den = np.linalg.norm(y - np.mean(y))
    if den < 1e-12:
        return 0.0
    return max(0.0, 100.0 * (1.0 - num / den))


def mse(y: np.ndarray, y_hat: np.ndarray) -> float:
    return float(np.mean((y - y_hat) ** 2))


def estimate_gain_and_delay(
    y_hat: np.ndarray, y: np.ndarray, ts: np.ndarray
) -> tuple[float, float]:
    y_hat_c = y_hat - np.mean(y_hat)
    y_c = y - np.mean(y)
    y_hat_std = np.std(y_hat_c)
    y_std = np.std(y_c)
    if y_hat_std < 1e-12 or y_std < 1e-12:
        return 0.0, 0.0
    gain = float(y_std / y_hat_std)
    xcorr = np.correlate(y_hat_c / y_hat_std, y_c / y_std, mode="full")
    lags = np.arange(-len(y_hat_c) + 1, len(y_hat_c))
    best_lag = lags[int(np.argmax(xcorr))]
    dt = float(np.median(np.diff(ts))) if len(ts) > 1 else 0.0
    return gain, float(best_lag * dt)


def compute_frequency_response(
    u: np.ndarray,
    y: np.ndarray,
    y_hat: np.ndarray,
    ts: np.ndarray,
    bandwidth_hz: float,
    coherence_threshold: float = 0.6,
) -> dict[str, Any]:
    u_c = u - np.mean(u)
    y_c = y - np.mean(y)
    y_hat_c = y_hat - np.mean(y_hat)
    dt = float(np.median(np.diff(ts))) if len(ts) > 1 else 1.0 / 250.0
    fs = 1.0 / dt
    nperseg = max(32, min(256, len(u_c) // 4))
    noverlap = nperseg // 2

    freq_coh, coh = signal.coherence(
        u_c, y_c, fs=fs, nperseg=nperseg, noverlap=noverlap
    )
    freq_psd, pyy = signal.welch(y_c, fs=fs, nperseg=nperseg, noverlap=noverlap)
    freq_csd, s_yhat_y = signal.csd(
        y_hat_c, y_c, fs=fs, nperseg=nperseg, noverlap=noverlap
    )

    if not (np.allclose(freq_coh, freq_psd) and np.allclose(freq_psd, freq_csd)):
        freq = freq_psd
        coh = np.interp(freq, freq_coh, coh)
        s_yhat_y = np.interp(freq, freq_csd, s_yhat_y.real) + 1j * np.interp(
            freq, freq_csd, s_yhat_y.imag
        )
    else:
        freq = freq_psd

    ratio = np.divide(
        s_yhat_y, pyy, out=np.zeros_like(s_yhat_y), where=np.abs(pyy) > 1e-15
    )
    rel_error = ratio - 1.0
    rel_error_mag_db = 20.0 * np.log10(np.abs(rel_error) + 1e-15)

    valid_phase = np.angle(ratio)
    unwrapped = np.unwrap(valid_phase)
    phase_bias_deg = np.degrees(unwrapped)
    phase_bias_deg = (phase_bias_deg + 180.0) % 360.0 - 180.0

    mask_bw = (freq >= 0.1) & (freq <= bandwidth_hz)
    mask_valid = mask_bw & (coh >= coherence_threshold) & (np.abs(pyy) > 1e-15)

    freq_valid = freq[mask_valid]
    rel_error_mag_db_valid = rel_error_mag_db[mask_valid]
    phase_bias_deg_valid = phase_bias_deg[mask_valid]
    coherence_valid = coh[mask_valid]

    if len(freq_valid) > 0:
        worst_rel_idx = int(np.argmax(np.abs(rel_error_mag_db_valid)))
        worst_phase_idx = int(np.argmax(np.abs(phase_bias_deg_valid)))
        worst_rel_error_db = float(rel_error_mag_db_valid[worst_rel_idx])
        worst_rel_error_freq_hz = float(freq_valid[worst_rel_idx])
        worst_phase_bias_deg = float(phase_bias_deg_valid[worst_phase_idx])
        worst_phase_bias_freq_hz = float(freq_valid[worst_phase_idx])
    else:
        worst_rel_error_db = 0.0
        worst_rel_error_freq_hz = 0.0
        worst_phase_bias_deg = 0.0
        worst_phase_bias_freq_hz = 0.0

    return {
        "freq": freq,
        "coherence_u_y": coh,
        "ratio_mag_db": 20.0 * np.log10(np.abs(ratio) + 1e-15),
        "phase_bias_deg": phase_bias_deg,
        "rel_error_mag_db": rel_error_mag_db,
        "valid_mask": mask_valid,
        "freq_valid": freq_valid,
        "coherence_valid": coherence_valid,
        "rel_error_mag_db_valid": rel_error_mag_db_valid,
        "phase_bias_deg_valid": phase_bias_deg_valid,
        "worst_rel_error_db": worst_rel_error_db,
        "worst_rel_error_freq_hz": worst_rel_error_freq_hz,
        "worst_phase_bias_deg": worst_phase_bias_deg,
        "worst_phase_bias_freq_hz": worst_phase_bias_freq_hz,
        "bandwidth_hz": bandwidth_hz,
        "coherence_threshold": coherence_threshold,
    }


def fit_oe_model(
    u: np.ndarray,
    y: np.ndarray,
    order: int,
    ts: np.ndarray | None = None,
    bandwidth_hz: float = 25.0,
) -> FitResult:
    u = np.asarray(u, dtype=float).ravel()
    y = np.asarray(y, dtype=float).ravel()
    y_centered = y - np.mean(y)

    if order == 1:
        theta0 = np.array([-0.5, 0.5])
        bounds = ([-2.0, -2.0], [2.0, 2.0])
        result = least_squares(
            residual_first_order,
            x0=theta0,
            args=(u, y_centered),
            method="trf",
            bounds=bounds,
            max_nfev=5000,
        )
        theta = result.x
        y_hat = simulate_oe_first_order(u, theta)
        poles = poles_first_order(theta)
    else:
        theta0 = np.array([-1.0, 0.3, 0.5, 0.1])
        bounds = ([-2.0, -2.0, -2.0, -2.0], [2.0, 2.0, 2.0, 2.0])
        result = least_squares(
            residual_second_order,
            x0=theta0,
            args=(u, y_centered),
            method="trf",
            bounds=bounds,
            max_nfev=5000,
        )
        theta = result.x
        y_hat = simulate_oe_second_order(u, theta)
        poles = poles_second_order(theta)

    gain, delay_sec = (0.0, 0.0)
    freq_response = None
    if ts is not None:
        gain, delay_sec = estimate_gain_and_delay(y_hat, y_centered, ts)
        freq_response = compute_frequency_response(
            u, y_centered, y_hat, ts, bandwidth_hz=bandwidth_hz
        )

    return FitResult(
        order=order,
        theta=theta,
        y_hat=y_hat,
        poles=poles,
        stable=is_stable(poles),
        fit_pct=fit_percent(y_centered, y_hat),
        mse_val=mse(y_centered, y_hat),
        success=bool(result.success),
        message=str(result.message),
        gain=gain,
        delay_sec=delay_sec,
        freq_response=freq_response,
    )


def format_transfer_function(result: FitResult) -> str:
    if result.order == 1:
        a1, b1 = result.theta
        return f"G(z) = ({b1:.6f} z^-1) / (1 + {a1:.6f} z^-1)"
    a1, a2, b1, b2 = result.theta
    return (
        f"G(z) = ({b1:.6f} z^-1 + {b2:.6f} z^-2) / (1 + {a1:.6f} z^-1 + {a2:.6f} z^-2)"
    )


def format_difference_equation(result: FitResult) -> str:
    if result.order == 1:
        a1, b1 = result.theta
        return f"y[k] = {-a1:.6f} y[k-1] + {b1:.6f} u[k-1]"
    a1, a2, b1, b2 = result.theta
    return f"y[k] = {-a1:.6f} y[k-1] + {-a2:.6f} y[k-2] + {b1:.6f} u[k-1] + {b2:.6f} u[k-2]"


def infer_primary_axis(ulg_name: str) -> str | None:
    name = ulg_name.lower()
    if "roll" in name:
        return "roll"
    if "pitch" in name:
        return "pitch"
    return None


def process_ulog_file(
    ulog: pyulog.ULog, config: dict, ulg_name: str
) -> dict[str, dict[str, Any]]:
    sample_rate = float(config["sample_rate_hz"])
    maneuver_cfg = config["maneuver_detection"]
    topics_cfg = config["topics"]
    ident_cfg = config["identification"]
    bandwidth_hz = float(ident_cfg.get("bandwidth_hz", 25.0))

    input_topic = get_topic_data(ulog, topics_cfg["input"]["topic"])
    output_topic = get_topic_data(ulog, topics_cfg["output"]["topic"])
    if input_topic is None or output_topic is None:
        raise ValueError(f"Required topics not found in {ulg_name}")

    ts_input = input_topic.data["timestamp"].astype(float) / 1e6
    ts_output = output_topic.data["timestamp"].astype(float) / 1e6
    ts_target = np.arange(
        max(ts_input[0], ts_output[0]),
        min(ts_input[-1], ts_output[-1]),
        1.0 / sample_rate,
    )

    primary_axis = infer_primary_axis(ulg_name)
    if primary_axis:
        print(f"  Detected primary axis: {primary_axis}")

    results: dict[str, dict[str, Any]] = {}
    for axis_cfg in ident_cfg["axes"]:
        axis_name = axis_cfg["name"]
        if primary_axis and axis_name != primary_axis:
            print(f"  [{axis_name}] Skipped (not primary axis)")
            continue

        u = resample_signal(
            ts_input, input_topic.data[axis_cfg["input_field"]].astype(float), ts_target
        )
        y = resample_signal(
            ts_output,
            output_topic.data[axis_cfg["output_field"]].astype(float),
            ts_target,
        )
        segments = detect_maneuver_segments(
            ts_target,
            u,
            maneuver_cfg["threshold_rad"],
            maneuver_cfg["min_duration_s"],
            maneuver_cfg.get("padding_samples", 10),
        )
        if not segments:
            print(f"  [{axis_name}] No maneuver segments found, skipping")
            continue

        segment = max(segments, key=lambda s: s[1] - s[0])
        ts_seg, u_seg, y_seg = extract_segment(ts_target, u, y, segment)
        print(
            f"  [{axis_name}] Selected segment: {segment[0]}-{segment[1]} ({len(ts_seg)} samples)"
        )

        min_samples = int(ident_cfg.get("min_maneuver_samples", 100))
        if len(ts_seg) < min_samples:
            print(
                f"  [{axis_name}] Insufficient maneuver samples ({len(ts_seg)} < {min_samples}), skipping"
            )
            continue

        corr = 0.0
        if np.std(u_seg) > 1e-12 and np.std(y_seg) > 1e-12:
            corr = float(
                np.corrcoef(u_seg - np.mean(u_seg), y_seg - np.mean(y_seg))[0, 1]
            )
        print(f"  [{axis_name}] Input-output correlation: {corr:.3f}")

        axis_result: dict[str, Any] = {
            "ts": ts_seg,
            "u": u_seg,
            "y": y_seg,
            "segment": segment,
            "correlation": corr,
            "fits": {},
        }
        for order in ident_cfg["try_orders"]:
            fit_res = fit_oe_model(
                u_seg, y_seg, int(order), ts=ts_seg, bandwidth_hz=bandwidth_hz
            )
            axis_result["fits"][int(order)] = fit_res
            fr = fit_res.freq_response or {}
            worst_rel = fr.get("worst_rel_error_db", 0.0)
            worst_phase = fr.get("worst_phase_bias_deg", 0.0)
            print(
                f"  [{axis_name}] {order}-order: fit={fit_res.fit_pct:.1f}%, "
                f"MSE={fit_res.mse_val:.6f}, gain={fit_res.gain:.3f}, "
                f"delay={fit_res.delay_sec * 1000:.1f}ms, "
                f"worst_rel={worst_rel:.2f}dB, worst_phase={worst_phase:.1f}deg"
            )

        best_order = max(
            axis_result["fits"], key=lambda k: axis_result["fits"][k].fit_pct
        )
        axis_result["best_order"] = best_order
        print(
            f"  [{axis_name}] Best: {best_order}-order (fit={axis_result['fits'][best_order].fit_pct:.1f}%)"
        )
        results[axis_name] = axis_result
    return results


def plot_data_filtering(
    ulg_name: str,
    results_by_axis: dict[str, dict[str, Any]],
    output_dir: Path,
    save_plot: bool,
):
    if not results_by_axis:
        return
    fig, axes = plt.subplots(
        len(results_by_axis), 1, figsize=(12, 4.5 * len(results_by_axis)), squeeze=False
    )
    for idx, (axis_name, axis_data) in enumerate(results_by_axis.items()):
        ax = axes[idx, 0]
        u_norm = (axis_data["u"] - np.mean(axis_data["u"])) / (
            np.std(axis_data["u"]) + 1e-12
        )
        y_norm = (axis_data["y"] - np.mean(axis_data["y"])) / (
            np.std(axis_data["y"]) + 1e-12
        )
        ax.plot(
            axis_data["ts"], u_norm, color="tab:blue", lw=1.2, label="input u (norm)"
        )
        ax.plot(
            axis_data["ts"], y_norm, color="tab:orange", lw=1.2, label="output y (norm)"
        )
        ax.set_title(f"{ulg_name} - {axis_name.upper()} segment")
        ax.set_xlabel("Time (s)")
        ax.set_ylabel("Normalized amplitude")
        ax.grid(True, alpha=0.3)
        ax.legend(loc="upper right", fontsize="small")
    plt.tight_layout()
    if save_plot:
        output_dir.mkdir(parents=True, exist_ok=True)
        plot_path = output_dir / f"{Path(ulg_name).stem}_data_filtering.png"
        plt.savefig(plot_path, dpi=150)
        print(f"  Data filtering plot saved: {plot_path}")
    plt.close(fig)


def plot_fit(
    ulg_name: str,
    results_by_axis: dict[str, dict[str, Any]],
    output_dir: Path,
    save_plot: bool,
):
    if not results_by_axis:
        return
    fig, axes = plt.subplots(
        len(results_by_axis), 1, figsize=(12, 4.5 * len(results_by_axis)), squeeze=False
    )
    colors = {1: "tab:blue", 2: "tab:orange"}
    for idx, (axis_name, axis_data) in enumerate(results_by_axis.items()):
        ax = axes[idx, 0]
        y_c = axis_data["y"] - np.mean(axis_data["y"])
        ax.plot(axis_data["ts"], y_c, color="k", lw=1.2, label="measured y")
        for order, fit_res in sorted(axis_data["fits"].items()):
            label = f"{order}-order (fit={fit_res.fit_pct:.1f}%)"
            if order == axis_data["best_order"]:
                label += " *"
            ax.plot(
                axis_data["ts"],
                fit_res.y_hat,
                color=colors.get(order, "tab:green"),
                lw=1.4,
                ls="--",
                label=label,
            )
        ax.set_title(f"{ulg_name} - {axis_name.upper()} fit")
        ax.set_xlabel("Time (s)")
        ax.set_ylabel("Rate (rad/s)")
        ax.grid(True, alpha=0.3)
        ax.legend(loc="upper right", fontsize="small")
    plt.tight_layout()
    if save_plot:
        output_dir.mkdir(parents=True, exist_ok=True)
        plot_path = output_dir / f"{Path(ulg_name).stem}_fit.png"
        plt.savefig(plot_path, dpi=150)
        print(f"  Fit plot saved: {plot_path}")
    plt.close(fig)


def plot_frequency_analysis(
    ulg_name: str,
    results_by_axis: dict[str, dict[str, Any]],
    output_dir: Path,
    save_plot: bool,
    bandwidth_hz: float,
):
    if not results_by_axis:
        return
    fig, axes = plt.subplots(
        len(results_by_axis), 3, figsize=(15, 4.2 * len(results_by_axis)), squeeze=False
    )
    colors = {1: "tab:blue", 2: "tab:orange"}
    for row, (axis_name, axis_data) in enumerate(results_by_axis.items()):
        ax_err = axes[row, 0]
        ax_phase = axes[row, 1]
        ax_coh = axes[row, 2]
        for order, fit_res in sorted(axis_data["fits"].items()):
            fr = fit_res.freq_response
            if fr is None:
                continue
            label = f"{order}-order"
            if order == axis_data["best_order"]:
                label += " *"
            color = colors.get(order, "tab:green")
            valid = fr["valid_mask"]
            ax_err.semilogx(
                fr["freq"][valid],
                fr["rel_error_mag_db"][valid],
                color=color,
                lw=1.4,
                label=label,
            )
            ax_phase.semilogx(
                fr["freq"][valid],
                fr["phase_bias_deg"][valid],
                color=color,
                lw=1.4,
                label=label,
            )
            ax_coh.semilogx(
                fr["freq"], fr["coherence_u_y"], color=color, lw=1.2, label=label
            )

        coh_thr = next(iter(axis_data["fits"].values())).freq_response[
            "coherence_threshold"
        ]
        ax_err.axhline(0.0, color="gray", ls="--", alpha=0.4)
        ax_phase.axhline(0.0, color="gray", ls="--", alpha=0.4)
        ax_coh.axhline(
            coh_thr, color="gray", ls="--", alpha=0.6, label=f"coh>{coh_thr:.1f}"
        )
        ax_err.set_title(f"{axis_name.upper()} relative error")
        ax_phase.set_title(f"{axis_name.upper()} phase bias")
        ax_coh.set_title(f"{axis_name.upper()} coherence (u->y)")
        ax_err.set_ylabel("Error (dB)")
        ax_phase.set_ylabel("Phase bias (deg)")
        ax_coh.set_ylabel("Coherence")
        ax_err.set_xlabel("Frequency (Hz)")
        ax_phase.set_xlabel("Frequency (Hz)")
        ax_coh.set_xlabel("Frequency (Hz)")
        for ax in (ax_err, ax_phase, ax_coh):
            ax.set_xlim(0.1, bandwidth_hz * 1.1)
            ax.grid(True, alpha=0.3, which="both")
            ax.legend(loc="upper right", fontsize="small")
    fig.suptitle(f"Frequency Analysis: {ulg_name}", fontsize=12)
    plt.tight_layout()
    if save_plot:
        output_dir.mkdir(parents=True, exist_ok=True)
        plot_path = output_dir / f"{Path(ulg_name).stem}_bode.png"
        plt.savefig(plot_path, dpi=150)
        print(f"  Frequency analysis plot saved: {plot_path}")
    plt.close(fig)


def save_params(all_results: dict[str, dict[str, Any]], output_dir: Path):
    output_dir.mkdir(parents=True, exist_ok=True)
    data: dict[str, Any] = {}
    for ulg_name, results_by_axis in all_results.items():
        data[Path(ulg_name).stem] = {}
        for axis_name, axis_data in results_by_axis.items():
            axis_out: dict[str, Any] = {
                "best_order": axis_data["best_order"],
                "correlation": float(axis_data["correlation"]),
                "models": {},
            }
            for order, fit_res in sorted(axis_data["fits"].items()):
                model_out: dict[str, Any] = {
                    "theta": [float(v) for v in fit_res.theta],
                    "transfer_function": format_transfer_function(fit_res),
                    "difference_equation": format_difference_equation(fit_res),
                    "fit_percent": float(fit_res.fit_pct),
                    "mse": float(fit_res.mse_val),
                    "gain": float(fit_res.gain),
                    "delay_ms": float(fit_res.delay_sec * 1000.0),
                    "poles": [complex(v) for v in fit_res.poles],
                    "stable": bool(fit_res.stable),
                }
                if fit_res.freq_response is not None:
                    fr = fit_res.freq_response
                    model_out["frequency_response"] = {
                        "worst_relative_error_db": float(fr["worst_rel_error_db"]),
                        "worst_relative_error_freq_hz": float(
                            fr["worst_rel_error_freq_hz"]
                        ),
                        "worst_phase_bias_deg": float(fr["worst_phase_bias_deg"]),
                        "worst_phase_bias_freq_hz": float(
                            fr["worst_phase_bias_freq_hz"]
                        ),
                        "bandwidth_hz": float(fr["bandwidth_hz"]),
                        "coherence_threshold": float(fr["coherence_threshold"]),
                    }
                axis_out["models"][f"{order}-order"] = model_out
            data[Path(ulg_name).stem][axis_name] = axis_out
    params_path = output_dir / "fitted_rate_params.yaml"
    with open(params_path, "w") as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)
    print(f"\nParameters saved: {params_path}")


def main():
    args = parse_args()
    script_dir = Path(__file__).parent
    config = load_config(str(script_dir / args.config))
    ulg_files = args.ulg if args.ulg else config["ulg_files"]
    output_cfg = config.get("output", {})
    results_dir = script_dir / output_cfg.get("results_dir", "results")
    bandwidth_hz = float(config.get("identification", {}).get("bandwidth_hz", 25.0))

    all_results: dict[str, dict[str, Any]] = {}
    for ulg_file in ulg_files:
        ulg_path = Path(ulg_file)
        if not ulg_path.is_absolute():
            ulg_path = script_dir / ulg_path
        print(f"\n{'=' * 60}")
        print(f"Processing: {ulg_path.name}")
        print("=" * 60)
        ulog = pyulog.ULog(str(ulg_path))
        results = process_ulog_file(ulog, config, ulg_path.name)
        all_results[ulg_path.name] = results
        if not args.no_plot:
            plot_data_filtering(
                ulg_path.name, results, results_dir, output_cfg.get("save_plots", True)
            )
            plot_fit(
                ulg_path.name, results, results_dir, output_cfg.get("save_plots", True)
            )
            plot_frequency_analysis(
                ulg_path.name,
                results,
                results_dir,
                output_cfg.get("save_plots", True),
                bandwidth_hz,
            )

    if output_cfg.get("save_params", True) and all_results:
        save_params(all_results, results_dir)

    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    for ulg_name, results in all_results.items():
        print(f"\n{ulg_name}:")
        for axis_name, axis_data in results.items():
            print(f"  [{axis_name.upper()}] correlation={axis_data['correlation']:.3f}")
            for order, fit_res in sorted(axis_data["fits"].items()):
                fr = fit_res.freq_response or {}
                marker = " *" if order == axis_data["best_order"] else ""
                print(
                    f"    {order}-order{marker}: fit={fit_res.fit_pct:.1f}%, gain={fit_res.gain:.3f}, "
                    f"delay={fit_res.delay_sec * 1000:.1f}ms, "
                    f"worst_rel={fr.get('worst_rel_error_db', 0.0):.2f}dB@{fr.get('worst_rel_error_freq_hz', 0.0):.1f}Hz, "
                    f"worst_phase={fr.get('worst_phase_bias_deg', 0.0):.1f}deg@{fr.get('worst_phase_bias_freq_hz', 0.0):.1f}Hz"
                )
                print(f"      {format_transfer_function(fit_res)}")


if __name__ == "__main__":
    main()
