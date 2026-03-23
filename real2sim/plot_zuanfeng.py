# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "pyulog",
#     "pyyaml",
#     "matplotlib",
#     "numpy",
# ]
# ///

import argparse
import re
from pathlib import Path

import numpy as np
import yaml
from matplotlib import pyplot as plt
import pyulog


def load_config(config_path: str) -> dict:
    with open(config_path, "r") as f:
        return yaml.safe_load(f)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Plot zuanfeng ULog data in 3x1 layout"
    )
    parser.add_argument(
        "--config",
        type=str,
        default="config_zuanfeng.yaml",
        help="Path to config YAML file (default: config_zuanfeng.yaml)",
    )
    parser.add_argument(
        "--ulg",
        type=str,
        default=None,
        help="Path to ULog file (overrides config)",
    )
    parser.add_argument(
        "--output",
        action="store_true",
        help="Export processed voltage/throttle/thrust CSV",
    )
    return parser.parse_args()


def get_topic_data(ulog: pyulog.ULog, topic_name: str):
    for d in ulog.data_list:
        if d.name == topic_name:
            return d
    return None


# === Filters ===


def range_filter(ulog: pyulog.ULog, config: dict) -> tuple[np.ndarray, np.ndarray]:
    topic_name = config["topic"]
    field = config["field"]
    center = config["center"]
    tolerance = config["tolerance"]

    topic_data = get_topic_data(ulog, topic_name)
    if topic_data is None:
        raise ValueError(f"Topic not found: {topic_name}")
    if field not in topic_data.data:
        raise ValueError(f"Field not found: {topic_name}.{field}")

    timestamps = topic_data.data["timestamp"].astype(np.float64)
    values = topic_data.data[field]

    lower = center - tolerance
    upper = center + tolerance
    mask = (values >= lower) & (values <= upper)

    print(f"[range_filter] {topic_name}.{field} in [{lower}, {upper}]")
    print(f"[range_filter] samples: {np.sum(mask)} / {len(mask)}")

    return timestamps, mask


def stability_filter(ulog: pyulog.ULog, config: dict) -> tuple[np.ndarray, np.ndarray]:
    topic_name = config["topic"]
    field = config["field"]
    window_size = config.get("window_size", 50)
    max_change = config.get("max_change", 0.01)

    topic_data = get_topic_data(ulog, topic_name)
    if topic_data is None:
        raise ValueError(f"Topic not found: {topic_name}")
    if field not in topic_data.data:
        raise ValueError(f"Field not found: {topic_name}.{field}")

    timestamps = topic_data.data["timestamp"].astype(np.float64)
    values = topic_data.data[field].astype(np.float64)

    n = len(values)
    mask = np.zeros(n, dtype=bool)

    for i in range(n):
        start_idx = max(0, i - window_size // 2)
        end_idx = min(n, i + window_size // 2 + 1)
        window_values = values[start_idx:end_idx]
        if len(window_values) > 0:
            window_range = np.max(window_values) - np.min(window_values)
            mask[i] = window_range <= max_change

    print(
        f"[stability_filter] {topic_name}.{field} window={window_size}, max_change={max_change}"
    )
    print(f"[stability_filter] samples: {np.sum(mask)} / {len(mask)}")

    return timestamps, mask


def trim_filter(mask: np.ndarray, config: dict) -> np.ndarray:
    trim_start_samples = config.get("trim_start_samples", 0)
    trim_end_samples = config.get("trim_end_samples", 0)
    result = mask.copy()
    if trim_start_samples > 0:
        result[:trim_start_samples] = False
    if trim_end_samples > 0:
        result[-trim_end_samples:] = False
    print(f"[trim_filter] trimmed start={trim_start_samples}, end={trim_end_samples}")
    return result


# === Registry ===

FILTERS = {
    "range_filter": range_filter,
    "stability_filter": stability_filter,
    "trim_filter": trim_filter,
}


# === Pipeline ===


def align_and_combine(
    base_ts: np.ndarray,
    base_mask: np.ndarray,
    other_ts: np.ndarray,
    other_mask: np.ndarray,
) -> np.ndarray:
    base_time_s = base_ts / 1_000_000.0
    other_time_s = other_ts / 1_000_000.0

    combined = base_mask.copy()
    other_idx = 0

    for i, t in enumerate(base_time_s):
        while other_idx < len(other_time_s) - 1 and other_time_s[other_idx + 1] <= t:
            other_idx += 1
        if other_idx < len(other_time_s) and abs(other_time_s[other_idx] - t) < 0.01:
            combined[i] = combined[i] and other_mask[other_idx]
        else:
            combined[i] = False

    return combined


def run_pipeline(
    ulog: pyulog.ULog, pipeline_config: list[dict]
) -> tuple[np.ndarray, np.ndarray]:
    ref_ts = None
    mask = None

    for step in pipeline_config:
        filter_type = step["type"]
        cfg = step.get("config", {})

        if filter_type not in FILTERS:
            raise ValueError(f"Unknown filter: {filter_type}")

        f = FILTERS[filter_type]

        if filter_type == "trim_filter":
            if mask is None:
                raise ValueError(
                    "trim_filter requires a preceding filter to establish mask"
                )
            mask = f(mask, cfg)
        else:
            ts, m = f(ulog, cfg)
            if mask is None:
                ref_ts = ts
                mask = m.copy()
            else:
                mask = align_and_combine(ref_ts, mask, ts, m)

        if mask is not None:
            print(f"[pipeline] current samples: {np.sum(mask)} / {len(mask)}")

    return ref_ts, mask


# === Plotting ===


def validate_topics(
    ulog: pyulog.ULog, config_topics: dict
) -> list[tuple[str, list[str]]]:
    ulog_topic_data = {d.name: d for d in ulog.data_list}
    ulog_topic_names = set(ulog_topic_data.keys())

    missing_topics = [t for t in config_topics if t not in ulog_topic_names]
    if missing_topics:
        raise ValueError(f"Topics not found in ULog: {missing_topics}")

    result = []
    all_missing_fields = []

    for topic_name, topic_config in config_topics.items():
        ulog_fields = set(ulog_topic_data[topic_name].data.keys())
        config_fields = topic_config["fields"]

        missing_fields = [f for f in config_fields if f not in ulog_fields]
        if missing_fields:
            all_missing_fields.extend([f"{topic_name}.{f}" for f in missing_fields])
        else:
            result.append((topic_name, config_fields))

    if all_missing_fields:
        raise ValueError(f"Fields not found in ULog: {all_missing_fields}")

    return result


def compute_avg_hz(timestamps: np.ndarray, sample_window: int) -> float:
    if len(timestamps) < sample_window + 1:
        return 0.0

    timestamps_us = timestamps.astype(np.float64)
    hz_values = []
    for i in range(len(timestamps_us) - sample_window):
        dt_us = timestamps_us[i + sample_window] - timestamps_us[i]
        if dt_us > 0:
            hz = sample_window * 1_000_000.0 / dt_us
            hz_values.append(hz)

    return np.mean(hz_values) if hz_values else 0.0


def get_filtered_time_ranges(
    ref_timestamps: np.ndarray,
    mask: np.ndarray,
    min_duration_s: float = 0.1,
) -> list[tuple[float, float]]:
    time_s = ref_timestamps / 1_000_000.0
    ranges = []
    in_range = False
    start_idx = 0

    for i, m in enumerate(mask):
        if m and not in_range:
            in_range = True
            start_idx = i
        elif not m and in_range:
            in_range = False
            if time_s[i - 1] - time_s[start_idx] >= min_duration_s:
                ranges.append((time_s[start_idx], time_s[i - 1]))

    if in_range:
        if time_s[-1] - time_s[start_idx] >= min_duration_s:
            ranges.append((time_s[start_idx], time_s[-1]))

    return ranges


def is_in_ranges(
    time_values: np.ndarray, ranges: list[tuple[float, float]]
) -> np.ndarray:
    result = np.zeros(len(time_values), dtype=bool)
    for start, end in ranges:
        result |= (time_values >= start) & (time_values <= end)
    return result


def build_correlation_samples(
    ulog: pyulog.ULog,
    time_ranges: list[tuple[float, float]],
    config: dict,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    thrust_topic = config["thrust"]["topic"]
    thrust_field = config["thrust"]["field"]
    voltage_topic = config["voltage"]["topic"]
    voltage_field = config["voltage"]["field"]
    accel_topic = config.get("acceleration", {}).get("topic", "vehicle_acceleration")
    accel_field = config.get("acceleration", {}).get("field", "xyz[2]")

    window_size = config.get("window_size", 50)

    thrust_data = get_topic_data(ulog, thrust_topic)
    voltage_data = get_topic_data(ulog, voltage_topic)
    accel_data = get_topic_data(ulog, accel_topic)

    if thrust_data is None:
        raise ValueError(f"Topic not found: {thrust_topic}")
    if voltage_data is None:
        raise ValueError(f"Topic not found: {voltage_topic}")
    if accel_data is None:
        raise ValueError(f"Topic not found: {accel_topic}")

    thrust_ts = thrust_data.data["timestamp"].astype(np.float64) / 1e6
    thrust_vals = thrust_data.data[thrust_field].astype(np.float64)
    voltage_ts = voltage_data.data["timestamp"].astype(np.float64) / 1e6
    voltage_vals = voltage_data.data[voltage_field].astype(np.float64)
    accel_ts = accel_data.data["timestamp"].astype(np.float64) / 1e6
    accel_vals = accel_data.data[accel_field].astype(np.float64)

    mask_thrust = is_in_ranges(thrust_ts, time_ranges)
    mask_voltage = is_in_ranges(voltage_ts, time_ranges)
    mask_accel = is_in_ranges(accel_ts, time_ranges)

    thrust_ts_f = thrust_ts[mask_thrust]
    thrust_vals_f = thrust_vals[mask_thrust]
    voltage_ts_f = voltage_ts[mask_voltage]
    voltage_vals_f = voltage_vals[mask_voltage]
    accel_ts_f = accel_ts[mask_accel]
    accel_vals_f = accel_vals[mask_accel]

    if len(thrust_ts_f) > 1:
        thrust_dt = np.median(np.diff(thrust_ts_f))
        thrust_hz = 1.0 / thrust_dt if thrust_dt > 0 else 286.0
    else:
        thrust_hz = 286.0

    print(f"[correlation] estimated thrust rate: {thrust_hz:.1f} Hz")

    if len(accel_ts_f) > 1:
        accel_dt = np.median(np.diff(accel_ts_f))
        accel_hz = 1.0 / accel_dt if accel_dt > 0 else thrust_hz
    else:
        accel_hz = thrust_hz

    throttle_mean_list = []
    voltage_list = []
    accel_mean_list = []

    for i, v_time in enumerate(voltage_ts_f):
        half_window_sec_thrust = (window_size // 2) / thrust_hz
        thrust_window_mask = (thrust_ts_f >= v_time - half_window_sec_thrust) & (
            thrust_ts_f <= v_time + half_window_sec_thrust
        )

        thrust_window_ts = thrust_ts_f[thrust_window_mask]
        thrust_in_window = thrust_vals_f[thrust_window_mask]

        if len(thrust_in_window) < window_size // 2:
            continue

        in_valid_segment = False
        for seg_start, seg_end in time_ranges:
            if thrust_window_ts[0] >= seg_start and thrust_window_ts[-1] <= seg_end:
                in_valid_segment = True
                break

        if in_valid_segment:
            half_window_sec_accel = (window_size // 2) / accel_hz
            accel_window_mask = (accel_ts_f >= v_time - half_window_sec_accel) & (
                accel_ts_f <= v_time + half_window_sec_accel
            )
            accel_window_ts = accel_ts_f[accel_window_mask]
            accel_in_window = accel_vals_f[accel_window_mask]

            if len(accel_in_window) < window_size // 2:
                continue

            accel_in_valid_segment = False
            for seg_start, seg_end in time_ranges:
                if accel_window_ts[0] >= seg_start and accel_window_ts[-1] <= seg_end:
                    accel_in_valid_segment = True
                    break

            if not accel_in_valid_segment:
                continue

            throttle_mean = np.mean(thrust_in_window)
            accel_mean = np.mean(accel_in_window)
            throttle_mean_list.append(throttle_mean)
            voltage_list.append(voltage_vals_f[i])
            accel_mean_list.append(accel_mean)

    throttle_arr = np.array(throttle_mean_list)
    voltage_arr = np.array(voltage_list)
    accel_mean_arr = np.array(accel_mean_list)

    return throttle_arr, voltage_arr, accel_mean_arr


def compute_correlation(
    ulog: pyulog.ULog,
    time_ranges: list[tuple[float, float]],
    config: dict,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, float]:
    window_size = config.get("window_size", 50)
    throttle_arr, voltage_arr, accel_mean_arr = build_correlation_samples(
        ulog, time_ranges, config
    )

    if len(throttle_arr) < 2:
        raise ValueError("Not enough data points for correlation")

    corr = np.corrcoef(throttle_arr, voltage_arr)[0, 1]

    print(f"[correlation] voltage points: {len(voltage_arr)}")
    print(f"[correlation] window_size: {window_size}")
    print(f"[correlation] r = {corr:.4f}")

    return throttle_arr, voltage_arr, accel_mean_arr, corr


def extract_total_thrust_grams(ulg_path: Path) -> int:
    stem = ulg_path.stem
    parts = stem.split("_")
    if len(parts) < 2:
        raise ValueError(f"Cannot parse thrust pattern from file name: {ulg_path.name}")

    thrust_part = parts[1]
    values = [int(v) for v in re.findall(r"(\d+)g", thrust_part)]
    if not values:
        values = [int(v) for v in re.findall(r"\d+", thrust_part)]

    if not values:
        raise ValueError(f"Cannot extract thrust grams from file name: {ulg_path.name}")

    return sum(values)


def save_processed_data(
    ulg_path: Path,
    voltage: np.ndarray,
    throttle_mean: np.ndarray,
    accel_mean: np.ndarray,
    output_dir: Path,
):
    total_thrust_g = extract_total_thrust_grams(ulg_path)
    mass_kg = total_thrust_g / 1000.0

    throttle = np.clip(-throttle_mean, 0.0, 1.0)
    thrust_n = mass_kg * np.abs(accel_mean)

    output_path = output_dir / f"zuanfeng_{total_thrust_g}g_data.csv"
    data = np.column_stack((voltage, throttle, thrust_n))

    np.savetxt(
        output_path,
        data,
        delimiter=",",
        header="voltage (V),throttle,thrust[N]",
        comments="",
        fmt="%.6f",
    )

    print(f"[output] saved processed data: {output_path}")
    print(f"[output] file mass tag: {total_thrust_g} g ({mass_kg:.4f} kg)")


def plot_topics_4x1(
    ulog: pyulog.ULog,
    topics: list[tuple[str, list[str]]],
    time_ranges: list[tuple[float, float]],
    sample_window: int,
    correlation_config: dict | None = None,
):
    n_topics = len(topics)
    has_correlation = correlation_config and correlation_config.get("enabled", False)
    n_rows = n_topics + 1 if has_correlation else n_topics

    fig, axes = plt.subplots(n_rows, 1, figsize=(12, 3 * n_rows), squeeze=False)
    axes = axes.flatten()

    for idx, (topic_name, fields) in enumerate(topics):
        ax = axes[idx]
        data = get_topic_data(ulog, topic_name)

        if data is None:
            ax.text(0.5, 0.5, f"No data for {topic_name}", ha="center", va="center")
            ax.set_title(f"{topic_name} (N/A)")
            continue

        timestamps = data.data["timestamp"]
        time_s = timestamps.astype(np.float64) / 1_000_000.0

        filter_mask = is_in_ranges(time_s, time_ranges)
        n_filtered = np.sum(filter_mask)
        avg_hz = (
            compute_avg_hz(timestamps[filter_mask], sample_window)
            if n_filtered > 0
            else 0.0
        )

        for field in fields:
            values = data.data[field]
            ax.scatter(
                time_s[filter_mask],
                values[filter_mask],
                s=2,
                alpha=0.7,
                label=f"{field} (n={n_filtered})",
            )

        ax.set_xlabel("Time (s)")
        ax.set_ylabel("Value")
        ax.set_title(f"{topic_name} ({avg_hz:.1f} Hz)")
        ax.legend(loc="upper right", fontsize="small")
        ax.grid(True, alpha=0.3)

    if has_correlation:
        ax = axes[n_topics]
        throttle_mean, voltage, _thrust_n, corr = compute_correlation(
            ulog, time_ranges, correlation_config
        )

        ax.scatter(throttle_mean, voltage, s=5, alpha=0.6)

        z = np.polyfit(throttle_mean, voltage, 1)
        p = np.poly1d(z)
        x_line = np.linspace(throttle_mean.min(), throttle_mean.max(), 100)
        ax.plot(x_line, p(x_line), "r--", linewidth=1.5, label=f"fit: r={corr:.4f}")

        ax.set_xlabel(
            f"{correlation_config['thrust']['topic']}.{correlation_config['thrust']['field']} (mean)"
        )
        ax.set_ylabel(
            f"{correlation_config['voltage']['topic']}.{correlation_config['voltage']['field']}"
        )
        ax.set_title(
            f"Correlation (window={correlation_config.get('window_size', 50)})"
        )
        ax.legend(loc="upper right", fontsize="small")
        ax.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.show()


def main():
    args = parse_args()

    script_dir = Path(__file__).parent
    config_path = script_dir / args.config
    config = load_config(config_path)

    ulg_path = args.ulg if args.ulg else config["ulg_file"]
    ulg_path = Path(ulg_path)
    if not ulg_path.is_absolute():
        ulg_path = script_dir / ulg_path

    print(f"Loading ULog: {ulg_path}")
    ulog = pyulog.ULog(str(ulg_path))

    print("Validating topics and fields...")
    valid_topics = validate_topics(ulog, config["topics"])
    print(f"Valid topics: {[t[0] for t in valid_topics]}")

    print("\nRunning pipeline...")
    ref_ts, mask = run_pipeline(ulog, config.get("pipeline", []))

    time_ranges = get_filtered_time_ranges(ref_ts, mask)
    print(f"\nFound {len(time_ranges)} segments")

    sample_window = config.get("sample_window", 5)
    correlation_config = config.get("correlation", None)

    if args.output and correlation_config and correlation_config.get("enabled", False):
        throttle_mean, voltage, thrust_n, _ = compute_correlation(
            ulog, time_ranges, correlation_config
        )
        save_processed_data(ulg_path, voltage, throttle_mean, thrust_n, script_dir)

    plot_topics_4x1(ulog, valid_topics, time_ranges, sample_window, correlation_config)


if __name__ == "__main__":
    main()
