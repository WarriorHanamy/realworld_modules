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
    delay_samples: int = 0
    model_type: str = "oe"


def create_fir_fit_result(
    b_coeffs: np.ndarray,
    y_hat: np.ndarray,
    u: np.ndarray,
    y: np.ndarray,
    delay: int,
    ts: np.ndarray | None,
    bandwidth_hz: float,
) -> FitResult:
    y_centered = y - np.mean(y)
    valid_start = delay + len(b_coeffs) - 1
    y_valid = y_centered[valid_start:]
    y_hat_valid = y_hat[valid_start:]
    u_valid = u[valid_start:]

    fit_pct = fit_percent(y_valid, y_hat_valid)
    mse_val = mse(y_valid, y_hat_valid)

    gain, delay_sec = 0.0, 0.0
    freq_response = None
    if ts is not None:
        ts_valid = ts[valid_start:]
        gain, delay_sec = estimate_gain_and_delay(y_hat_valid, y_valid, ts_valid)
        freq_response = compute_frequency_response(
            u_valid, y_valid, y_hat_valid, ts_valid, bandwidth_hz=bandwidth_hz
        )

    return FitResult(
        order=len(b_coeffs),
        theta=b_coeffs,
        y_hat=y_hat,
        poles=np.array([]),
        stable=True,
        fit_pct=fit_pct,
        mse_val=mse_val,
        success=True,
        message="FIR fit",
        gain=gain,
        delay_sec=delay_sec,
        freq_response=freq_response,
        delay_samples=delay,
        model_type="fir",
    )


def create_iir_fit_result(
    theta: np.ndarray,
    y_hat: np.ndarray,
    u: np.ndarray,
    y: np.ndarray,
    delay: int,
    order: int,
    ts: np.ndarray | None,
    bandwidth_hz: float,
) -> FitResult:
    a_coeffs = theta[:order]
    poles = np.roots([1.0] + list(a_coeffs))
    stable = bool(np.all(np.abs(poles) < 1.0))

    valid_start = delay + order
    y_valid = y[valid_start:]
    y_hat_valid = y_hat[valid_start:]
    u_valid = u[valid_start:]

    fit_pct = fit_percent(y_valid, y_hat_valid)
    mse_val = mse(y_valid, y_hat_valid)

    gain, delay_sec = 0.0, 0.0
    freq_response = None
    if ts is not None:
        ts_valid = ts[valid_start:]
        gain, delay_sec = estimate_gain_and_delay(y_hat_valid, y_valid, ts_valid)
        freq_response = compute_frequency_response(
            u_valid, y_valid, y_hat_valid, ts_valid, bandwidth_hz=bandwidth_hz
        )

    return FitResult(
        order=order,
        theta=theta,
        y_hat=y_hat,
        poles=poles,
        stable=stable,
        fit_pct=fit_pct,
        mse_val=mse_val,
        success=True,
        message="IIR fit with delay",
        gain=gain,
        delay_sec=delay_sec,
        freq_response=freq_response,
        delay_samples=delay,
        model_type="iir_delay",
    )


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


def simulate_iir_with_delay(
    u: np.ndarray, theta: np.ndarray, delay: int, y_init: float | None = None
) -> np.ndarray:
    a_coeffs = theta[: len(theta) // 2]
    b_coeffs = theta[len(theta) // 2 :]
    order = len(a_coeffs)

    y_hat = np.zeros(len(u), dtype=float)
    if y_init is not None:
        y_hat[: delay + order] = y_init

    for k in range(delay + order, len(u)):
        y_hat[k] = sum(-a_coeffs[i] * y_hat[k - 1 - i] for i in range(order))
        y_hat[k] += sum(b_coeffs[i] * u[k - delay - i] for i in range(order))
    return y_hat


def fit_iir_with_delay(
    u: np.ndarray, y: np.ndarray, order: int, max_delay: int = 4
) -> tuple[np.ndarray | None, int, np.ndarray | None, float]:
    y_mean = np.mean(y)
    best_theta = None
    best_delay = 0
    best_y_hat = None
    best_fit = -1.0

    for delay in range(max_delay + 1):
        X_rows = []
        y_vals = []
        for k in range(delay + order, len(u)):
            row = [-y[k - 1 - i] for i in range(order)] + [
                u[k - delay - i] for i in range(order)
            ]
            X_rows.append(row)
            y_vals.append(y[k])

        if len(X_rows) < 2 * order:
            continue

        X = np.array(X_rows)
        y_vec = np.array(y_vals)

        theta, _, _, _ = np.linalg.lstsq(X, y_vec, rcond=None)

        a_coeffs = theta[:order]
        poles = np.roots([1.0] + list(a_coeffs))
        if not np.all(np.abs(poles) < 1.0):
            continue

        y_hat = simulate_iir_with_delay(u, theta, delay, y_init=y_mean)

        valid_start = delay + order
        fit = fit_percent(y[valid_start:], y_hat[valid_start:])

        if fit > best_fit:
            best_fit = fit
            best_theta = theta
            best_delay = delay
            best_y_hat = y_hat

    return best_theta, best_delay, best_y_hat, best_fit


def residual_first_order(theta: np.ndarray, u: np.ndarray, y: np.ndarray) -> np.ndarray:
    return simulate_oe_first_order(u, theta) - y


def residual_second_order(
    theta: np.ndarray, u: np.ndarray, y: np.ndarray
) -> np.ndarray:
    return simulate_oe_second_order(u, theta) - y


def residual_third_order(theta: np.ndarray, u: np.ndarray, y: np.ndarray) -> np.ndarray:
    return simulate_oe_third_order(u, theta) - y


def poles_first_order(theta: np.ndarray) -> np.ndarray:
    return np.array([-theta[0]])


def poles_second_order(theta: np.ndarray) -> np.ndarray:
    return np.roots([1.0, theta[0], theta[1]])


def poles_third_order(theta: np.ndarray) -> np.ndarray:
    return np.roots([1.0, theta[0], theta[1], theta[2]])


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
    elif order == 2:
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
    else:
        theta0 = np.array([-1.5, 0.5, -0.1, 0.5, 0.2, 0.05])
        bounds = ([-2.0, -2.0, -2.0, -2.0, -2.0, -2.0], [2.0, 2.0, 2.0, 2.0, 2.0, 2.0])
        result = least_squares(
            residual_third_order,
            x0=theta0,
            args=(u, y_centered),
            method="trf",
            bounds=bounds,
            max_nfev=5000,
        )
        theta = result.x
        y_hat = simulate_oe_third_order(u, theta)
        poles = poles_third_order(theta)

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


def simulate_oe_with_delay(
    u: np.ndarray, theta: np.ndarray, order: int, delay_samples: int
) -> np.ndarray:
    u_shifted = (
        np.roll(u, -delay_samples) if delay_samples < 0 else np.roll(u, delay_samples)
    )
    if delay_samples > 0:
        u_shifted[:delay_samples] = 0
    elif delay_samples < 0:
        u_shifted[delay_samples:] = 0

    if order == 1:
        return simulate_oe_first_order(u_shifted, theta)
    elif order == 2:
        return simulate_oe_second_order(u_shifted, theta)
    else:
        return simulate_oe_third_order(u_shifted, theta)


def fit_oe_model_with_delay(
    u: np.ndarray,
    y: np.ndarray,
    order: int,
    ts: np.ndarray | None = None,
    bandwidth_hz: float = 25.0,
    max_delay_ms: float = 100.0,
) -> tuple[FitResult, int]:
    u = np.asarray(u, dtype=float).ravel()
    y = np.asarray(y, dtype=float).ravel()
    y_centered = y - np.mean(y)

    if ts is None or len(ts) < 2:
        dt = 1.0 / 400.0
    else:
        dt = float(np.median(np.diff(ts)))

    max_delay_samples = int(max_delay_ms / 1000.0 / dt)

    best_fit = -1.0
    best_result = None
    best_delay_samples = 0

    for delay_samples in range(
        0, max_delay_samples + 1, max(1, max_delay_samples // 10)
    ):
        u_shifted = np.roll(u, delay_samples)
        u_shifted[:delay_samples] = 0

        result = fit_oe_model(
            u_shifted, y_centered, order, ts=None, bandwidth_hz=bandwidth_hz
        )
        if result.fit_pct > best_fit:
            best_fit = result.fit_pct
            best_result = result
            best_delay_samples = delay_samples

    if ts is not None and best_result is not None:
        gain, delay_sec = estimate_gain_and_delay(best_result.y_hat, y_centered, ts)
        freq_response = compute_frequency_response(
            u, y_centered, best_result.y_hat, ts, bandwidth_hz=bandwidth_hz
        )
        best_result = FitResult(
            order=best_result.order,
            theta=best_result.theta,
            y_hat=best_result.y_hat,
            poles=best_result.poles,
            stable=best_result.stable,
            fit_pct=best_result.fit_pct,
            mse_val=best_result.mse_val,
            success=best_result.success,
            message=best_result.message,
            gain=gain,
            delay_sec=delay_sec,
            freq_response=freq_response,
        )

    return best_result, best_delay_samples


def format_transfer_function(result: FitResult) -> str:
    model_type = getattr(result, "model_type", "oe")
    delay = getattr(result, "delay_samples", 0)

    if model_type == "fir":
        b_coeffs = result.theta
        terms = [f"{b:.6f} z^-{delay + i}" for i, b in enumerate(b_coeffs)]
        return f"H(z) = {' + '.join(terms)}"

    if model_type == "iir_delay":
        order = result.order
        a_coeffs = result.theta[:order]
        b_coeffs = result.theta[order:]
        num_terms = [f"{b:.6f} z^-{delay + i}" for i, b in enumerate(b_coeffs)]
        den_terms = ["1"] + [f"{a:.6f} z^-{i + 1}" for i, a in enumerate(a_coeffs)]
        return (
            f"H(z) = z^-{delay} * ({' + '.join(num_terms)}) / ({' + '.join(den_terms)})"
        )

    if result.order == 1:
        a1, b1 = result.theta
        return f"G(z) = ({b1:.6f} z^-1) / (1 + {a1:.6f} z^-1)"
    if result.order == 2:
        a1, a2, b1, b2 = result.theta
        return f"G(z) = ({b1:.6f} z^-1 + {b2:.6f} z^-2) / (1 + {a1:.6f} z^-1 + {a2:.6f} z^-2)"
    a1, a2, a3, b1, b2, b3 = result.theta
    return (
        f"G(z) = ({b1:.6f} z^-1 + {b2:.6f} z^-2 + {b3:.6f} z^-3) / "
        f"(1 + {a1:.6f} z^-1 + {a2:.6f} z^-2 + {a3:.6f} z^-3)"
    )


def format_difference_equation(result: FitResult) -> str:
    model_type = getattr(result, "model_type", "oe")
    delay = getattr(result, "delay_samples", 0)

    if model_type == "fir":
        b_coeffs = result.theta
        terms = [f"{b:.6f} u[k-{i + delay}]" for i, b in enumerate(b_coeffs)]
        return f"y[k] = {' + '.join(terms)}"

    if model_type == "iir_delay":
        order = result.order
        a_coeffs = result.theta[:order]
        b_coeffs = result.theta[order:]
        y_terms = [f"{-a:.6f} y[k-{i + 1}]" for i, a in enumerate(a_coeffs)]
        u_terms = [f"{b:.6f} u[k-{delay + i}]" for i, b in enumerate(b_coeffs)]
        return f"y[k] = {' + '.join(y_terms)} + {' + '.join(u_terms)}"

    if result.order == 1:
        a1, b1 = result.theta
        return f"y[k] = {-a1:.6f} y[k-1] + {b1:.6f} u[k-1]"
    if result.order == 2:
        a1, a2, b1, b2 = result.theta
        return f"y[k] = {-a1:.6f} y[k-1] + {-a2:.6f} y[k-2] + {b1:.6f} u[k-1] + {b2:.6f} u[k-2]"
    a1, a2, a3, b1, b2, b3 = result.theta
    return (
        f"y[k] = {-a1:.6f} y[k-1] + {-a2:.6f} y[k-2] + {-a3:.6f} y[k-3] + "
        f"{b1:.6f} u[k-1] + {b2:.6f} u[k-2] + {b3:.6f} u[k-3]"
    )


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

    dt_output = np.diff(ts_output)
    actual_rate_output = 1.0 / np.median(dt_output) if len(dt_output) > 0 else 0.0
    rate_ratio = actual_rate_output / sample_rate
    print(
        f"  Output topic sampling: actual={actual_rate_output:.1f}Hz, "
        f"configured={sample_rate:.1f}Hz, ratio={rate_ratio:.3f}"
    )
    if rate_ratio < 0.8 or rate_ratio > 1.2:
        print(
            f"  WARNING: Actual sampling rate differs significantly from configured rate!"
        )
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

        min_samples = int(ident_cfg.get("min_maneuver_samples", 100))
        valid_segments = [s for s in segments if (s[1] - s[0] + 1) >= min_samples]
        if not valid_segments:
            print(f"  [{axis_name}] No segments with sufficient samples, skipping")
            continue

        best_segment = None
        best_fit_pct = -1.0
        best_axis_result = None
        order_to_try = min(ident_cfg["try_orders"])
        max_delay = int(ident_cfg.get("max_delay", 4))

        print(f"  [{axis_name}] Evaluating {len(valid_segments)} segments...")
        for idx, segment in enumerate(valid_segments):
            ts_seg, u_seg, y_seg = extract_segment(ts_target, u, y, segment)
            if np.std(u_seg) < 1e-12 or np.std(y_seg) < 1e-12:
                continue
            theta, delay, y_hat, fit_pct = fit_iir_with_delay(
                u_seg, y_seg, int(order_to_try), max_delay=max_delay
            )
            if theta is not None and fit_pct > best_fit_pct:
                best_fit_pct = fit_pct
                best_segment = segment
                corr = float(
                    np.corrcoef(u_seg - np.mean(u_seg), y_seg - np.mean(y_seg))[0, 1]
                )
                best_axis_result = {
                    "ts": ts_seg,
                    "u": u_seg,
                    "y": y_seg,
                    "segment": segment,
                    "correlation": corr,
                    "fits": {},
                }

        if best_segment is None:
            print(f"  [{axis_name}] No valid segment found after evaluation")
            continue

        ts_seg = best_axis_result["ts"]
        u_seg = best_axis_result["u"]
        y_seg = best_axis_result["y"]
        print(
            f"  [{axis_name}] Best segment: {best_segment[0]}-{best_segment[1]} "
            f"({len(ts_seg)} samples, prelim fit={best_fit_pct:.1f}%)"
        )

        corr = best_axis_result["correlation"]
        print(f"  [{axis_name}] Input-output correlation: {corr:.3f}")

        for order in ident_cfg["try_orders"]:
            theta, delay, y_hat, _ = fit_iir_with_delay(
                u_seg, y_seg, int(order), max_delay=max_delay
            )
            if theta is None:
                print(f"  [{axis_name}] IIR-{order} D=? unstable, skipped")
                continue
            fit_res = create_iir_fit_result(
                theta, y_hat, u_seg, y_seg, delay, int(order), ts_seg, bandwidth_hz
            )
            best_axis_result["fits"][int(order)] = fit_res
            fr = fit_res.freq_response or {}
            worst_rel = fr.get("worst_rel_error_db", 0.0)
            worst_phase = fr.get("worst_phase_bias_deg", 0.0)
            print(
                f"  [{axis_name}] IIR-{order} D={delay}: fit={fit_res.fit_pct:.1f}%, "
                f"MSE={fit_res.mse_val:.6f}, gain={fit_res.gain:.3f}, "
                f"worst_rel={worst_rel:.2f}dB, worst_phase={worst_phase:.1f}deg"
            )

        best_order = max(
            best_axis_result["fits"], key=lambda k: best_axis_result["fits"][k].fit_pct
        )
        best_axis_result["best_order"] = best_order
        print(
            f"  [{axis_name}] Best: {best_order}-order (fit={best_axis_result['fits'][best_order].fit_pct:.1f}%)"
        )
        results[axis_name] = best_axis_result
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
                model_type = getattr(fit_res, "model_type", "oe")
                model_out: dict[str, Any] = {
                    "model_type": model_type,
                    "theta": [float(v) for v in fit_res.theta],
                    "transfer_function": format_transfer_function(fit_res),
                    "difference_equation": format_difference_equation(fit_res),
                    "fit_percent": float(fit_res.fit_pct),
                    "mse": float(fit_res.mse_val),
                    "gain": float(fit_res.gain),
                    "delay_ms": float(fit_res.delay_sec * 1000.0),
                    "stable": bool(fit_res.stable),
                }
                if model_type in ("fir", "iir_delay"):
                    model_out["delay_samples"] = int(
                        getattr(fit_res, "delay_samples", 0)
                    )
                if model_type in ("oe", "iir_delay"):
                    model_out["poles"] = [complex(v) for v in fit_res.poles]
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
                model_key = (
                    f"FIR-{order}taps"
                    if model_type == "fir"
                    else f"IIR-{order}"
                    if model_type == "iir_delay"
                    else f"{order}-order"
                )
                axis_out["models"][model_key] = model_out
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
                model_type = getattr(fit_res, "model_type", "oe")
                delay_samples = getattr(fit_res, "delay_samples", 0)
                if model_type == "fir":
                    model_name = f"FIR-{order}taps D={delay_samples}"
                elif model_type == "iir_delay":
                    model_name = f"IIR-{order} D={delay_samples}"
                else:
                    model_name = f"{order}-order"
                print(
                    f"    {model_name}{marker}: fit={fit_res.fit_pct:.1f}%, gain={fit_res.gain:.3f}, "
                    f"delay={fit_res.delay_sec * 1000:.1f}ms, "
                    f"worst_rel={fr.get('worst_rel_error_db', 0.0):.2f}dB@{fr.get('worst_rel_error_freq_hz', 0.0):.1f}Hz, "
                    f"worst_phase={fr.get('worst_phase_bias_deg', 0.0):.1f}deg@{fr.get('worst_phase_bias_freq_hz', 0.0):.1f}Hz"
                )
                print(f"      {format_transfer_function(fit_res)}")


if __name__ == "__main__":
    main()
