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
        description="User movement intention visualization"
    )
    parser.add_argument(
        "--ulg",
        type=str,
        default=None,
        help="Path to ULog file (overrides config)",
    )
    parser.add_argument(
        "--output",
        type=str,
        default=None,
        help="Output PNG file path (default: show plot)",
    )
    return parser.parse_args()


def get_topic_data(ulog: pyulog.ULog, topic_name: str):
    for d in ulog.data_list:
        if d.name == topic_name:
            return d
    return None


def thrust_model(
    V: np.ndarray, u: np.ndarray, K1: float, K2: float, K3: float
) -> np.ndarray:
    return K1 * np.power(V, K2) * (K3 * u**2 + (1 - K3) * u)


def main():
    args = parse_args()

    script_dir = Path(__file__).parent
    config_path = script_dir / "config_thrust_viz.yaml"
    config = load_config(config_path)

    ulg_path = args.ulg if args.ulg else config["ulg_file"]
    ulg_path = Path(ulg_path)
    if not ulg_path.is_absolute():
        ulg_path = script_dir / ulg_path

    print(f"Loading ULog: {ulg_path}")
    ulog = pyulog.ULog(str(ulg_path))

    thr_map_path = script_dir / config.get("thr_map", "thr_map.yaml")
    thr_map = load_config(thr_map_path)
    print(f"Loaded thrust map: {thr_map_path}")

    tv = config["thrust_viz"]
    thrust_topic = tv["thrust"]["topic"]
    thrust_field = tv["thrust"]["field"]
    accel_topic = tv["acceleration"]["topic"]
    accel_field = tv["acceleration"]["field"]
    voltage_topic = tv["voltage"]["topic"]
    voltage_field = tv["voltage"]["field"]

    thrust_data = get_topic_data(ulog, thrust_topic)
    accel_data = get_topic_data(ulog, accel_topic)
    voltage_data = get_topic_data(ulog, voltage_topic)

    if not all([thrust_data, accel_data, voltage_data]):
        missing = []
        if not thrust_data:
            missing.append(thrust_topic)
        if not accel_data:
            missing.append(accel_topic)
        if not voltage_data:
            missing.append(voltage_topic)
        raise ValueError(f"Missing topics: {missing}")

    K1 = thr_map["thr_map"]["K1"]
    K2 = thr_map["thr_map"]["K2"]
    K3 = thr_map["thr_map"]["K3"]

    thrust_ts = thrust_data.data["timestamp"].astype(np.float64) / 1e6
    thrust_u = -thrust_data.data[thrust_field]

    accel_ts = accel_data.data["timestamp"].astype(np.float64) / 1e6
    accel_z_raw = -accel_data.data[accel_field]

    voltage_ts = voltage_data.data["timestamp"].astype(np.float64) / 1e6
    voltage_v_raw = voltage_data.data[voltage_field]

    voltage_interp = np.interp(thrust_ts, voltage_ts, voltage_v_raw)
    accel_z_interp = np.interp(thrust_ts, accel_ts, accel_z_raw)

    predicted_thrust = thrust_model(voltage_interp, thrust_u, K1, K2, K3)

    mass_kg = tv.get("mass_kg")
    if mass_kg:
        predicted_accel = predicted_thrust / mass_kg
        ylabel = "Acceleration Z (m/s²)"
    else:
        predicted_accel = predicted_thrust
        ylabel = "Thrust (N) / Accel (m/s²)"

    plot_range = config.get("plot_range", {})
    start_idx = plot_range.get("start", 0)
    end_idx = plot_range.get("end", len(thrust_ts))

    common_ts = thrust_ts[start_idx:end_idx]
    predicted_accel = predicted_accel[start_idx:end_idx]
    actual_accel = accel_z_interp[start_idx:end_idx]
    throttle_plot = thrust_u[start_idx:end_idx]
    voltage_plot = voltage_interp[start_idx:end_idx]

    calibration_range = config.get("calibration_range", {})
    show_throttle_voltage = config.get("show_throttle_voltage", False)

    if show_throttle_voltage:
        fig, axes = plt.subplots(3, 1, figsize=(12, 12), sharex=True)
    else:
        fig, axes = plt.subplots(1, 1, figsize=(12, 4), sharex=True)
        axes = [axes]

    ax1 = axes[0]
    ax1.plot(
        common_ts,
        actual_accel,
        label=f"Actual {accel_topic}.{accel_field}",
        linewidth=0.8,
        alpha=0.7,
    )
    ax1.plot(
        common_ts,
        predicted_accel,
        label=f"Predicted thrust acceleration command (from thr_model)",
        linewidth=0.8,
        alpha=0.7,
    )
    ax1.set_ylabel(ylabel)
    ax1.set_title("User Movement Intention: Predicted vs Actual Acceleration")
    ax1.legend(loc="upper right")
    ax1.grid(True, alpha=0.3)

    if show_throttle_voltage:
        ax2 = axes[1]
        ax2.plot(
            common_ts, throttle_plot, "b-", label="Throttle", linewidth=0.8, alpha=0.7
        )
        ax2.set_ylabel("Throttle")
        ax2.set_title("Throttle")
        ax2.legend(loc="upper right")
        ax2.grid(True, alpha=0.3)

        ax3 = axes[2]
        ax3.plot(
            common_ts, voltage_plot, "r-", label="Voltage", linewidth=0.8, alpha=0.7
        )
        ax3.set_xlabel("Time (s)")
        ax3.set_ylabel("Voltage (V)")
        ax3.set_title("Voltage")
        ax3.legend(loc="upper right")
        ax3.grid(True, alpha=0.3)

        if calibration_range:
            throttle_min = calibration_range.get("throttle_min")
            throttle_max = calibration_range.get("throttle_max")
            voltage_min = calibration_range.get("voltage_min")
            voltage_max = calibration_range.get("voltage_max")

            if throttle_min is not None:
                ax2.axhline(
                    y=throttle_min,
                    color="g",
                    linestyle="--",
                    alpha=0.7,
                    label="Calib min",
                )
            if throttle_max is not None:
                ax2.axhline(
                    y=throttle_max,
                    color="g",
                    linestyle="--",
                    alpha=0.7,
                    label="Calib max",
                )
            if voltage_min is not None:
                ax3.axhline(
                    y=voltage_min,
                    color="g",
                    linestyle="--",
                    alpha=0.7,
                    label="Calib min",
                )
            if voltage_max is not None:
                ax3.axhline(
                    y=voltage_max,
                    color="g",
                    linestyle="--",
                    alpha=0.7,
                    label="Calib max",
                )
    else:
        ax1.set_xlabel("Time (s)")

    plt.tight_layout()

    if args.output:
        plt.savefig(args.output, dpi=150)
        print(f"Plot saved to: {args.output}")
    else:
        plt.show()


if __name__ == "__main__":
    main()
