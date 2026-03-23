#!/usr/bin/env python3
"""
Thrust model fitting script.
Formula: F = K1 * Voltage^K2 * (K3 * u^2 + (1-K3) * u)
Metrics: MSE (optimization), MAPE (evaluation)
"""

import glob
import os
import numpy as np
from scipy.optimize import curve_fit
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d import Axes3D


def thrust_model(V_u, K1, K2, K3):
    V, u = V_u
    return K1 * np.power(V, K2) * (K3 * u**2 + (1 - K3) * u)


def compute_mse(actual, predicted):
    return np.mean((actual - predicted) ** 2)


def compute_mape(actual, predicted):
    return np.mean(np.abs((actual - predicted) / actual)) * 100


def load_csv_data(filepath):
    data = np.loadtxt(filepath, delimiter=",", skiprows=1)
    voltage = data[:, 0]
    throttle = data[:, 1]
    thrust = data[:, 2]
    return voltage, throttle, thrust


def main():
    csv_pattern = os.path.join(os.path.dirname(__file__), "zuanfeng*.csv")
    csv_files = sorted(glob.glob(csv_pattern))

    if not csv_files:
        print("No CSV files found!")
        return

    print(f"Found {len(csv_files)} CSV files:")
    for f in csv_files:
        print(f"  - {os.path.basename(f)}")
    print()

    all_voltage = []
    all_throttle = []
    all_thrust = []
    datasets = []

    for filepath in csv_files:
        v, u, f = load_csv_data(filepath)
        all_voltage.extend(v)
        all_throttle.extend(u)
        all_thrust.extend(f)
        datasets.append(
            {
                "name": os.path.basename(filepath),
                "voltage": v,
                "throttle": u,
                "thrust": f,
            }
        )

    all_voltage = np.array(all_voltage)
    all_throttle = np.array(all_throttle)
    all_thrust = np.array(all_thrust)

    print(f"Total data points: {len(all_thrust)}")
    print(f"Voltage range: {all_voltage.min():.2f} - {all_voltage.max():.2f} V")
    print(f"Throttle range: {all_throttle.min():.4f} - {all_throttle.max():.4f}")
    print(f"Thrust range: {all_thrust.min():.2f} - {all_thrust.max():.2f} N")
    print()

    V_u_combined = (all_voltage, all_throttle)

    bounds = ([0, 0, 0], [np.inf, np.inf, 1])
    initial_guess = [0.1, 1.0, 0.5]

    print("Fitting thrust model...")
    popt, pcov = curve_fit(
        thrust_model,
        V_u_combined,
        all_thrust,
        p0=initial_guess,
        bounds=bounds,
        maxfev=10000,
    )

    K1, K2, K3 = popt

    print("\n" + "=" * 50)
    print("FITTED PARAMETERS")
    print("=" * 50)
    print(f"K1 = {K1:.6f}")
    print(f"K2 = {K2:.6f}")
    print(f"K3 = {K3:.6f}")
    print()

    all_predicted = thrust_model(V_u_combined, K1, K2, K3)

    total_mse = compute_mse(all_thrust, all_predicted)
    total_mape = compute_mape(all_thrust, all_predicted)

    print("=" * 50)
    print("OVERALL METRICS")
    print("=" * 50)
    print(f"MSE  = {total_mse:.6f} N^2")
    print(f"RMSE = {np.sqrt(total_mse):.6f} N")
    print(f"MAPE = {total_mape:.4f} %")
    print()

    print("=" * 50)
    print("PER-DATASET METRICS")
    print("=" * 50)

    for ds in datasets:
        V_u_ds = (ds["voltage"], ds["throttle"])
        pred_ds = thrust_model(V_u_ds, K1, K2, K3)
        mse_ds = compute_mse(ds["thrust"], pred_ds)
        mape_ds = compute_mape(ds["thrust"], pred_ds)
        print(f"{ds['name']:30s}  MSE={mse_ds:.6f}  MAPE={mape_ds:.4f}%")

    print()

    output_dir = os.path.dirname(__file__)
    fig, axes = plt.subplots(1, 2, figsize=(12, 5))

    ax1 = axes[0]
    colors = plt.cm.tab10(np.linspace(0, 1, len(datasets)))
    for i, ds in enumerate(datasets):
        V_u_ds = (ds["voltage"], ds["throttle"])
        pred_ds = thrust_model(V_u_ds, K1, K2, K3)
        ax1.scatter(
            ds["thrust"],
            pred_ds,
            c=[colors[i]],
            label=ds["name"].replace("zuanfeng_", "").replace("_data.csv", ""),
            alpha=0.5,
            s=10,
        )

    min_val = all_thrust.min()
    max_val = all_thrust.max()
    ax1.plot([min_val, max_val], [min_val, max_val], "k--", lw=2, label="Perfect fit")
    ax1.set_xlabel("Actual Thrust (N)")
    ax1.set_ylabel("Predicted Thrust (N)")
    ax1.set_title(f"Predicted vs Actual\nK1={K1:.4f}, K2={K2:.4f}, K3={K3:.4f}")
    ax1.legend(fontsize=8)
    ax1.grid(True, alpha=0.3)
    ax1.set_aspect("equal")

    ax2 = axes[1]
    residuals = all_thrust - all_predicted
    relative_errors = (residuals / all_thrust) * 100

    ax2.hist(relative_errors, bins=50, edgecolor="black", alpha=0.7)
    ax2.axvline(x=0, color="r", linestyle="--", lw=2)
    ax2.set_xlabel("Relative Error (%)")
    ax2.set_ylabel("Count")
    ax2.set_title(f"Error Distribution (MAPE={total_mape:.2f}%)")
    ax2.grid(True, alpha=0.3)

    plt.tight_layout()
    output_path = os.path.join(output_dir, "fitting_result.png")
    plt.savefig(output_path, dpi=150)
    print(f"Plot saved to: {output_path}")

    # 3D Mesh Plot
    fig3d = plt.figure(figsize=(10, 8))
    ax3d = fig3d.add_subplot(111, projection="3d")

    V_grid = np.linspace(all_voltage.min(), all_voltage.max(), 50)
    u_grid = np.linspace(all_throttle.min(), all_throttle.max(), 50)
    V_mesh, u_mesh = np.meshgrid(V_grid, u_grid)
    F_mesh = K1 * np.power(V_mesh, K2) * (K3 * u_mesh**2 + (1 - K3) * u_mesh)

    ax3d.plot_surface(
        V_mesh, u_mesh, F_mesh, alpha=0.6, cmap="viridis", linewidth=0, antialiased=True
    )

    colors = plt.cm.tab10(np.linspace(0, 1, len(datasets)))
    for i, ds in enumerate(datasets):
        label = ds["name"].replace("zuanfeng_", "").replace("_data.csv", "")
        ax3d.scatter(
            ds["voltage"],
            ds["throttle"],
            ds["thrust"],
            c=[colors[i]],
            label=label,
            s=15,
            alpha=0.8,
        )

    ax3d.set_xlabel("Voltage (V)")
    ax3d.set_ylabel("Throttle")
    ax3d.set_zlabel("Thrust (N)")
    ax3d.set_title(f"3D Thrust Model Fit\nK1={K1:.4f}, K2={K2:.4f}, K3={K3:.4f}")
    ax3d.legend(fontsize=8, loc="upper left")

    mesh_path = os.path.join(output_dir, "fitting_3d_mesh.png")
    plt.savefig(mesh_path, dpi=150)
    print(f"3D mesh plot saved to: {mesh_path}")

    params_path = os.path.join(output_dir, "fitted_params.txt")
    with open(params_path, "w") as f:
        f.write(f"# Fitted Thrust Model Parameters\n")
        f.write(f"# Formula: F = K1 * Voltage^K2 * (K3 * u^2 + (1-K3) * u)\n")
        f.write(f"K1 = {K1:.10f}\n")
        f.write(f"K2 = {K2:.10f}\n")
        f.write(f"K3 = {K3:.10f}\n")
        f.write(f"\n# Metrics\n")
        f.write(f"MSE = {total_mse:.10f}\n")
        f.write(f"RMSE = {np.sqrt(total_mse):.10f}\n")
        f.write(f"MAPE = {total_mape:.10f}\n")
    print(f"Parameters saved to: {params_path}")

    print("\n" + "=" * 50)
    print("FOR ROS PARAM SERVER (YAML format)")
    print("=" * 50)
    print(f"thr_map:")
    print(f"  K1: {K1:.10f}")
    print(f"  K2: {K2:.10f}")
    print(f"  K3: {K3:.10f}")


if __name__ == "__main__":
    main()
