# VTOL Neural Infer Jetson Pipeline Plan

## Intent

Create a jetson deployment pipeline for the vtol_behavior_manager's neural inference system, including:
1. A policy sync script that scp's policies from host `$HOME/server/policies` to jetson `/home/nv/server/policies`
2. A neural inference run script with 3 automatic substeps: sync policies, run inference, monitor
3. A monitor script that attaches to the running inference container
4. Integration with existing run_scripts conventions

## Feasibility

**Feasible** - The vtol_behavior_manager already has:
- A working `neural-infer` Makefile target for simulation
- A `sync-policies` target that copies policies to containers
- A jetson deployment image (`vtol/bht-jetson:latest`) built via `docker-build-ros2-jetson`
- Existing run script conventions and tmux utilities
- Device configuration in `sync_service/sync_env`

## Context

### Current Simulation Workflow
1. `make sync-policies`: Copies policies from `/home/rec/server/policies` to bht container's `/home/ros/policies`
2. `make neural-infer`: Depends on sync-policies, runs `python3 -m neural_manager.neural_inference.neural_infer` in container

### Jetson Deployment Requirements
- **Policy Sync**: scp from `$HOME/server/policies` (host) to `/home/nv/server/policies` (jetson)
- **Inference**: 3 automatic substeps:
  1. Sync policies to jetson
  2. Run neural inference container
  3. Monitor/attach to running container
- **Monitor**: Run specific docker command to attach to inference container
- Use `vtol/bht-jetson:latest` image
- Follow run_scripts naming convention: `run-jetson-prod-{feature}.sh`

> **Architecture Note**: `production.sh` now uses an alternative approach—after the `neural-executor-jetson` container starts, inference is launched via `docker exec` inside the same container rather than a separate `docker run`. This reduces overhead and guarantees a shared environment. `run-jetson-prod-neural-infer.sh` retains the standalone-container pattern for isolated debugging.

### Key Files
- `vtol_behavior_manager/Makefile`: Contains sync-policies and neural-infer targets
- `run_scripts/tmux_utils.sh`: tmux orchestration helpers
- `sync_service/sync_env`: Device configuration (IP, user, paths)
- `vtol_behavior_manager/src/neural_manager/neural_inference/neural_infer.py`: Main inference entry point

## Task

### Parent Task
Create a complete jetson deployment pipeline for neural inference that:
1. Syncs policies from host `$HOME/server/policies` to jetson `/home/nv/server/policies`
2. Runs neural inference with 3 automatic substeps
3. Provides monitoring/attach capability
4. Follows project conventions for run scripts

### Child Tasks

#### Child Task 1: Create Policy Sync Script (`run-jetson-sync-policies.sh`)
**Deliverable**: A script that syncs policies from host to jetson using scp
**Source Path**: `$HOME/server/policies` (host)
**Target Path**: `/home/nv/server/policies` (jetson)
**Device Config**: Use `sync_service/sync_env` (DEVICE_IP, DEVICE_USER, SSH_KEY)
**Dependencies**: None
**Completion Criteria**:
- Script uses scp with SSH options from sync_env
- Creates target directory on jetson if needed
- Handles errors gracefully
- Follows bash script conventions (strict mode, proper quoting)
- Provides clear success/failure feedback

#### Child Task 2: Create Neural Infer Run Script (`run-jetson-prod-neural-infer.sh`)
**Deliverable**: `run-jetson-prod-neural-infer.sh` script with 3 automatic substeps
**Substeps**:
1. **Sync Policies**: Call `run-jetson-sync-policies.sh` to sync policies to jetson
2. **Run Inference**: Start neural inference container on jetson using:
   ```bash
   docker run --rm \
     --platform linux/arm64 \
     --net=host \
     --ipc=host \
     --privileged \
     -e ROS_DOMAIN_ID=30 \
     -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
     -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
     vtol/bht-jetson:latest \
     bash -c "set +u; source /opt/ros/humble/setup.bash && source /home/ros/ros2_ws/install/setup.bash && PYTHONPATH=/home/ros/ros2_ws/src:\$PYTHONPATH python3 -m neural_manager.neural_inference.neural_infer; set -u; exec bash"
   ```
3. **Monitor**: Attach to running container or provide status
**Dependencies**: Child Task 1 (policy sync)
**Completion Criteria**:
- Uses `vtol/bht-jetson:latest` image
- Includes policy sync as first step
- Sets ROS_DOMAIN_ID=30
- Properly sources ROS2 environment
- Runs neural inference automatically
- Provides monitoring capability
- Follows existing run script patterns

#### Child Task 3: Create Monitor Script (`run-jetson-monitor-neural-infer.sh`)
**Deliverable**: A script that attaches to running neural inference container
**Docker Command**:
```bash
docker run --rm \
  --platform linux/arm64 \
  --net=host \
  --ipc=host \
  --privileged \
  -e ROS_DOMAIN_ID=30 \
  -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e FASTRTPS_DEFAULT_PROFILES_FILE=/etc/fastdds/fastdds.xml \
  vtol/bht-jetson:latest \
  bash -c "set +u; source /opt/ros/humble/setup.bash && source /home/ros/ros2_ws/install/setup.bash; set -u; exec bash"
```
**Dependencies**: Child Task 2 (inference running)
**Completion Criteria**:
- Attaches to running inference container
- Provides interactive shell access
- Allows monitoring of inference logs
- Can be used independently or as part of tmux session

## Constraints

1. **Platform**: Must work on jetson (arm64) with Docker
2. **ROS2 Domain**: Must use ROS_DOMAIN_ID=30
3. **Network**: Must use `--network host` and `--ipc host`
4. **Image**: Must use `vtol/bht-jetson:latest`
5. **Policies**:
   - Source: `$HOME/server/policies` (host)
   - Target: `/home/nv/server/policies` (jetson)
   - Must sync policies before running inference
6. **Naming**: Must follow `run-jetson-prod-{feature}.sh` convention
7. **Docker Run**: Must use specific docker run command for monitoring

## Verification

### Deliverables Verification
1. **Policy Sync Script** (`run-jetson-sync-policies.sh`):
   - [ ] Script exists and is executable
   - [ ] Uses scp with SSH options from sync_env
   - [ ] Syncs from `$HOME/server/policies` to `/home/nv/server/policies`
   - [ ] Creates target directory on jetson if needed
   - [ ] Handles connection errors
   - [ ] Provides clear success/failure feedback

2. **Neural Infer Run Script** (`run-jetson-prod-neural-infer.sh`):
   - [ ] Script exists and is executable
   - [ ] Uses `vtol/bht-jetson:latest` image
   - [ ] Includes 3 automatic substeps:
     - [ ] Step 1: Sync policies
     - [ ] Step 2: Run inference container
     - [ ] Step 3: Monitor/attach
   - [ ] Sets ROS_DOMAIN_ID=30
   - [ ] Sources ROS2 environment correctly
   - [ ] Runs neural inference automatically

3. **Monitor Script** (`run-jetson-monitor-neural-infer.sh`):
   - [ ] Script exists and is executable
   - [ ] Uses correct docker command for monitoring
   - [ ] Attaches to running inference container
   - [ ] Provides interactive shell access

### Acceptance Criteria
- [ ] Can sync policies from host `$HOME/server/policies` to jetson `/home/nv/server/policies`
- [ ] Can run neural inference on jetson with 3 automatic substeps
- [ ] Can monitor running inference container
- [ ] Follows project conventions
- [ ] Handles errors gracefully
- [ ] Provides clear user feedback

## Rules

1. **No Code Changes**: This is a planning task only
2. **Convention Compliance**: Must follow existing run_scripts patterns
3. **Docker Conventions**: Must use --network host, --ipc host, ROS_DOMAIN_ID=30
4. **Error Handling**: Scripts must fail fast with clear error messages
5. **Documentation**: Scripts should include usage comments
6. **Automatic Execution**: Neural inference must run with 3 automatic substeps
7. **Monitoring**: Must provide monitoring capability using specified docker command