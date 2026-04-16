#!/usr/bin/env python3
import sys
import math


def rot_x(angle):
    c, s = math.cos(angle), math.sin(angle)
    return [[1, 0, 0], [0, c, -s], [0, s, c]]


def rot_z(angle):
    c, s = math.cos(angle), math.sin(angle)
    return [[c, -s, 0], [s, c, 0], [0, 0, 1]]


def mat_mul(A, B):
    return [
        [sum(A[i][k] * B[k][j] for k in range(3)) for j in range(3)] for i in range(3)
    ]


def rotation_matrix(roll_deg, pitch_deg, yaw_deg):
    """Compute R_z(yaw) * R_z(pitch) * R_x(roll) from Euler angles in degrees."""
    roll = math.radians(roll_deg)
    pitch = math.radians(pitch_deg)
    yaw = math.radians(yaw_deg)
    R = mat_mul(rot_z(yaw), mat_mul(rot_z(pitch), rot_x(roll)))
    return R


def main():
    if len(sys.argv) != 4:
        print("Usage: cal_rot.py <roll_deg> <pitch_deg> <yaw_deg>")
        sys.exit(1)

    roll = float(sys.argv[1])
    pitch = float(sys.argv[2])
    yaw = float(sys.argv[3])

    R = rotation_matrix(roll, pitch, yaw)

    # Output (1): 3-line rotation matrix
    print("Rotation matrix:")
    for row in R:
        print(" ".join(f"{v:.6f}" for v in row))

    # Output (2): single-line bracket format with commas
    flat = [v for row in R for v in row]
    bracket = "[" + ", ".join(f"{v:.6f}" for v in flat) + "]"
    print("\nSingle line:")
    print(bracket)


if __name__ == "__main__":
    main()
