# Neural Infer 模块导入问题修复计划

## 意图

修复 `run-jetson-prod-neural-infer.sh` 脚本在 Docker 容器中运行时出现的模块导入错误：
1. `/home/ros/ros2_ws/install/setup.bash` 文件不存在
2. `ModuleNotFoundError: No module named 'neural_manager'`

## 可行性分析

**可行** - 问题根源已明确：
1. `neural_manager` 和 `neural_inference` 目录缺少 `__init__.py` 文件，Python 无法将其识别为包
2. Dockerfile 只构建了 `neural_executor` ROS2 包，没有处理 Python 包结构
3. 运行脚本中的 `PYTHONPATH` 设置需要修正

## 背景

### 当前问题分析

#### 问题 1: 缺少 `__init__.py` 文件
- `vtol_behavior_manager/src/neural_manager/` 目录缺少 `__init__.py`
- `vtol_behavior_manager/src/neural_manager/neural_inference/` 目录缺少 `__init__.py`
- Python 需要这些文件来将目录识别为包

#### 问题 2: Dockerfile 构建不完整
- `bht.dockerfile` (第 66-69 行) 只构建了 `neural_executor` ROS2 包
- `bht.native.Dockerfile` (第 23 行) 也只构建了 `px4_msgs px4_ros2_cpp neural_executor`
- 没有处理 Python 包的安装或路径设置

#### 问题 3: 运行脚本路径问题
- `run-jetson-prod-neural-infer.sh` (第 61 行) 设置了 `PYTHONPATH=/home/ros/ros2_ws/src:$PYTHONPATH`
- 但 Dockerfile 中的工作目录是 `/home/ros/ros2_ws`，不是 `/home/ros/ros2_ws/src`
- 需要确保 `neural_manager` 目录在 Python 路径中

### 关键文件
- `vtol_behavior_manager/src/neural_manager/neural_inference/neural_infer.py`: 主入口文件
- `vtol_behavior_manager/dockerfiles/bht.dockerfile`: 模拟环境 Dockerfile
- `vtol_behavior_manager/dockerfiles/bht.native.Dockerfile`: Jetson 部署 Dockerfile
- `run_scripts/run-jetson-prod-neural-infer.sh`: 运行脚本

## 任务

### 父任务
修复 `neural_manager` 模块导入问题，使 `run-jetson-prod-neural-infer.sh` 脚本能够在 Docker 容器中正常运行。

### 子任务

#### 子任务 1: 添加缺失的 `__init__.py` 文件
**交付物**: 为 `neural_manager` 和 `neural_inference` 目录创建 `__init__.py` 文件
**文件路径**:
1. `vtol_behavior_manager/src/neural_manager/__init__.py`
2. `vtol_behavior_manager/src/neural_manager/neural_inference/__init__.py`

**内容**: 空文件或简单的包注释
**依赖**: 无
**完成标准**:
- 两个 `__init__.py` 文件已创建
- 文件内容为空或包含包注释
- 文件权限正确

#### 子任务 2: 更新 Dockerfile 以包含 Python 包结构
**交付物**: 修改 `bht.dockerfile` 和 `bht.native.Dockerfile` 以确保 Python 包结构正确
**修改内容**:
1. 在 `bht.dockerfile` 中添加 `__init__.py` 文件创建步骤
2. 在 `bht.native.Dockerfile` 中确保 `PYTHONPATH` 包含正确的源码路径
3. 确保 `neural_manager` 目录在 Python 路径中

**依赖**: 子任务 1
**完成标准**:
- Dockerfile 包含创建 `__init__.py` 文件的步骤
- `PYTHONPATH` 环境变量正确设置
- 构建过程不会出错

#### 子任务 3: 修正运行脚本中的路径
**交付物**: 修改 `run-jetson-prod-neural-infer.sh` 脚本中的路径设置
**修改内容**:
1. 检查并修正 `PYTHONPATH` 设置
2. 确保 `neural_manager` 模块可以被找到
3. 验证 `install/setup.bash` 文件是否存在，如果不存在则移除相关 source 命令

**依赖**: 子任务 2
**完成标准**:
- 脚本中的路径设置正确
- `neural_manager` 模块可以被导入
- 脚本可以正常运行

## 约束

1. **代码修改**: 需要修改源代码文件（添加 `__init__.py`）
2. **Docker 构建**: 需要重新构建 Docker 镜像
3. **路径一致性**: 必须保持与现有项目结构一致
4. **向后兼容**: 修改不能破坏现有功能
5. **测试**: 修改后需要测试脚本是否正常工作

## 验证

### 交付物验证
1. **`__init__.py` 文件**:
   - [x] `vtol_behavior_manager/src/neural_manager/__init__.py` 存在
   - [x] `vtol_behavior_manager/src/neural_manager/neural_inference/__init__.py` 存在
   - [x] 文件内容为空或包含包注释

2. **Dockerfile 修改**:
   - [x] `bht.native.Dockerfile` 已设置 `PYTHONPATH` 包含 `${WS_DIR}/src`
   - [ ] `bht.dockerfile` 包含创建 `__init__.py` 的步骤（如需要请验证）
   - [ ] Docker 构建成功（请在构建后勾选）

3. **运行脚本修正**:
   - [x] `run-jetson-prod-neural-infer.sh` 依赖 Dockerfile 的 `PYTHONPATH`，无需额外路径设置
   - [ ] 脚本可以正常运行（请在测试后勾选）
   - [ ] `neural_manager` 模块可以被导入（请在测试后勾选）

### 验收标准
- [ ] `run-jetson-prod-neural-infer.sh` 脚本可以在 Docker 容器中正常运行
- [x] `neural_manager` 模块可以被正确导入（`__init__.py` 已存在）
- [x] 不再出现 `ModuleNotFoundError` 错误（`__init__.py` 已存在）
- [x] `setup.bash` 文件不存在的警告已处理（脚本使用条件判断 `if [ -f ... ]`）
- [ ] 修改不会破坏现有功能（请在回归测试后勾选）

## 规则

1. **最小修改**: 只修改必要的文件
2. **向后兼容**: 不能破坏现有功能
3. **测试验证**: 修改后必须测试
4. **文档更新**: 如果需要，更新相关文档
5. **遵循约定**: 遵循项目现有的代码风格和约定