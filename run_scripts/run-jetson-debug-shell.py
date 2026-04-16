#!/usr/bin/env python3
"""
Run an interactive debug shell inside the PX4 connector Jetson container.
Sources ROS2 Humble and PX4 workspace, with FastDDS debug configuration.
"""

import argparse
import subprocess
import sys
from pathlib import Path


def get_script_dir() -> Path:
    """Get the directory containing this script."""
    return Path(__file__).resolve().parent


def validate_image(image: str) -> bool:
    """Check if Docker image exists locally."""
    result = subprocess.run(
        ["docker", "image", "inspect", image],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"ERROR: Docker image '{image}' not found.", file=sys.stderr)
        print(f"Build it with: make docker-build-px4-connector-jetson", file=sys.stderr)
        return False
    return True


def validate_config(config_path: Path) -> bool:
    """Check if FastDDS config file exists."""
    if not config_path.exists():
        print(f"ERROR: FastDDS config not found: {config_path}", file=sys.stderr)
        return False
    return True


def cleanup_containers(image: str) -> None:
    """Stop and remove existing containers from the same image."""
    print(f"[INFO] Cleaning up existing containers from image: {image}...")
    # Stop running containers
    subprocess.run(
        ["docker", "ps", "-q", "--filter", f"ancestor={image}"],
        capture_output=True,
    )
    # Remove all containers (running and stopped)
    result = subprocess.run(
        ["docker", "ps", "-a", "-q", "--filter", f"ancestor={image}"],
        capture_output=True,
        text=True,
    )
    container_ids = result.stdout.strip().split("\n") if result.stdout.strip() else []
    if container_ids:
        subprocess.run(["docker", "rm", "-f"] + container_ids, capture_output=True)
        print(f"[INFO] Removed {len(container_ids)} container(s)")
    else:
        print("[INFO] No existing containers to remove")


def build_docker_command(
    image: str,
    fastdds_config: Path,
    command: str | None = None,
) -> list[str]:
    """Build the docker run command."""
    script_dir = get_script_dir()
    config_abs = fastdds_config.resolve()

    # Override entrypoint to bash
    docker_cmd = [
        "docker",
        "run",
        "--rm",
        "-it",
        "--network",
        "host",
        "--ipc",
        "host",
        "--privileged",
        "--entrypoint",
        "bash",
        "-e",
        "ROS_DOMAIN_ID=30",
        "-e",
        "RMW_IMPLEMENTATION=rmw_fastrtps_cpp",
        "-e",
        "FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml",
        "-v",
        f"{config_abs}:/etc/fastdds/fastdds.xml:ro",
        image,
    ]

    if command:
        docker_cmd.extend(["-c", command])
    else:
        # Default: interactive bash with ROS and PX4 sourced
        docker_cmd.extend(
            [
                "-c",
                "set +u; source /opt/ros/humble/setup.bash; "
                "source /root/px4_connector_ws/install/setup.bash; set -u; exec bash",
            ]
        )

    return docker_cmd


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run an interactive debug shell in the PX4 connector Jetson container"
    )
    parser.add_argument(
        "--image",
        default="vtol/px4-connector-jetson:latest",
        help="Docker image to use (default: %(default)s)",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=get_script_dir() / "config" / "fastdds-debug.xml",
        help="FastDDS configuration file (default: %(default)s)",
    )
    parser.add_argument(
        "--command",
        "-c",
        help="Run a custom command instead of interactive shell",
    )
    parser.add_argument(
        "--no-cleanup",
        action="store_true",
        help="Skip cleanup of existing containers",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print docker command without executing",
    )

    args = parser.parse_args()

    # Validate prerequisites
    if not validate_image(args.image):
        return 1

    if not validate_config(args.config):
        return 1

    # Cleanup existing containers unless disabled
    if not args.no_cleanup:
        cleanup_containers(args.image)

    # Build and run docker command
    docker_cmd = build_docker_command(args.image, args.config, args.command)

    print(f"[INFO] Starting container: {args.image}")
    print(f"[INFO] FastDDS config: {args.config}")
    print(f"[INFO] Docker command: {' '.join(docker_cmd)}")

    if args.dry_run:
        print("[INFO] Dry-run mode: not executing command")
        return 0

    try:
        result = subprocess.run(docker_cmd, check=False)
        return result.returncode
    except KeyboardInterrupt:
        print("\n[INFO] Interrupted by user")
        return 130
    except Exception as e:
        print(f"ERROR: Failed to run docker command: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
