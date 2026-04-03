# vtol_deployment

`vtol_deployment` is the integration layer that coordinates how the VTOL stack is
developed in simulation and then composed into real-world operation.

## Architecture Intent

The deployment model is split into two layers:

- `vtol_interface/`: upper-layer application logic, including the simulation-first
  state machine, neural inference, and PX4-facing application behavior.
- `linker/`: backend integration utilities that connect sensors, odometry, and PX4
  runtime interfaces in the real world.

The important point is that `vtol_interface` is not only a simulator playground.
It is the upper-layer behavior stack that is developed and validated against a
simulation backend first.

## Simulation-First, Real-World Later

During development, `vtol_interface` runs against a simulation backend.

- `vtol_interface/docker-compose.yml` is the simulation setup.
- It brings up sim-side dependencies such as PX4 SITL, Gazebo, QGroundControl,
  and ROS 2 development containers.
- This compose file is for simulation-oriented development and testing, not for
  defining the full real-world deployment layout.

During real-world deployment, the upper-layer logic remains the same while the
simulation backend is replaced by real-world providers from `linker/`.

- `linker/lio/` provides LiDAR and odometry-side runtime pieces.
- `linker/px4_connector/` provides PX4-facing ROS 2 bridge functionality.
- `linker/calibration/` provides calibration utilities used to support the real
  sensor stack.

In other words, the real-world capability is the composition of:

- `vtol_interface` as the upper-layer autonomy/application stack
- `linker` as the real-world backend/provider layer

`vtol_deployment` is the place where this relationship is defined.

## Reading Guide

- Read `vtol_interface/` when working on simulation-first state-machine,
  neural inference, and sim-side orchestration.
- Read `linker/` when working on hardware-facing runtime bridges, sensor input,
  odometry providers, and PX4 real-world connectivity.
- Read `vtol_interface/services/README.md` for simulation session management.
- Read `linker/px4_connector/README.md` for the current PX4 odometry bridge scope.

## Scope Boundary

Some subdirectories under `vtol_interface/` and `linker/` have their own local
context or originate from upstream/vendor-style code. Their local README files
describe module-local behavior.

This top-level document is the authoritative place for explaining how those
pieces fit together at the system level.
