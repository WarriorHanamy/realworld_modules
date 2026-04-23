# Run Scripts 命名约定评估结果

## 意图澄清结果

### 用户原始请求
用户提出将 run 脚本的命名约定从 `run_{service}_{platform}.sh` 改为 `run-{host/jetson}-{debug/\0}-{feature}.sh`。

### 澄清后的意图
用户希望引入一个更结构化的命名约定，明确区分平台（host/jetson）和调试模式（debug/非调试）。

## 当前状态

### 现有约定
- 模式: `run_{service}_{platform}.sh`
- 文档位置: `AGENTS.md` 第 24-29 行
- 符合约定的脚本: 15 个
- 不符合约定的脚本: 1 个 (`run_livox_driver.sh`)

### 新提议约定
- 模式: `run-{platform}-{debug/空}-{feature}.sh`
- 示例: `run-jetson-debug-ros2.sh`, `run-host--px4.sh`
- 问题: `\0` 表示空，导致非调试模式时产生双连字符

## 可行性评估

### 技术可行性: ✅ 可行
- 文件重命名是简单的文件系统操作
- 没有代码直接依赖 run 脚本文件名
- Makefile 定义自己的目标，不引用 run 脚本

### 实施复杂度: 🟡 中等
- 需要重命名 16 个文件
- 需要更新 AGENTS.md 文档
- 可能需要更新相关文档和示例

### 风险评估: 🟢 低风险
- 主要风险是破坏用户习惯和文档引用
- 没有技术依赖性风险

## 问题分析

### 新约定的优点
1. **明确调试模式**: 通过 `debug` 标识清楚区分调试版本
2. **结构化**: 平台和调试模式作为独立字段
3. **一致性**: 使用连字符与 Makefile 目标风格一致

### 新约定的缺点
1. **双连字符问题**: 非调试模式时产生 `run-host--feature.sh` 格式
2. **迁移成本**: 需要重命名 16 个文件
3. **解析复杂**: 文件名解析比当前约定更复杂

## 替代方案建议

### 方案 1: 保持当前约定，但添加调试后缀
- 模式: `run_{service}_{platform}[_debug].sh`
- 示例: `run_ros2_jetson.sh`, `run_ros2_jetson_debug.sh`
- 优点: 兼容现有约定，调试模式可选
- 缺点: 调试标识在平台之后，不够突出

### 方案 2: 修改新约定，使用可选调试标识
- 模式: `run-{platform}[-debug]-{feature}.sh`
- 示例: `run-jetson-ros2.sh`, `run-jetson-debug-ros2.sh`
- 优点: 避免双连字符，调试模式可选
- 缺点: 需要解析可选部分

### 方案 3: 完全采用用户提议，但使用明确的空值
- 模式: `run-{platform}-{mode}-{feature}.sh` (mode: debug|prod)
- 示例: `run-jetson-debug-ros2.sh`, `run-jetson-prod-px4.sh`
- 优点: 模式明确，无歧义
- 缺点: 增加 "prod" 标识，可能冗余

## 用户决策

**选择的方案**: 方案 3 - `run-{platform}-{mode}-{feature}.sh` (mode: debug|prod)

### 方案详情
- **模式**: `run-{platform}-{mode}-{feature}.sh`
- **平台**: `jetson` 或 `host`
- **模式**: `debug` 或 `prod`
- **功能**: 服务名称
- **示例**: 
  - `run-jetson-debug-ros2.sh`
  - `run-jetson-prod-px4.sh`
  - `run-host-debug-ros2.sh`
  - `run-host-prod-plotjuggler.sh`

### 实施计划

#### 1. 更新文档
- 更新 `AGENTS.md` 中的 Run Scripts Convention 部分
- 记录新的命名约定和模式

#### 2. 重命名现有脚本
需要重命名的脚本 (16个):
1. `run_calib_jetson.sh` → `run-jetson-prod-calib.sh`
2. `run_lidar_discovery_jetson.sh` → `run-jetson-prod-lidar-discovery.sh`
3. `run_lio_jetson.sh` → `run-jetson-prod-lio.sh`
4. `run_lio_rviz_host.sh` → `run-host-prod-lio-rviz.sh`
5. `run_lio_shell_host.sh` → `run-host-prod-lio-shell.sh`
6. `run_lio_upstream_livox_jetson.sh` → `run-jetson-prod-lio-upstream-livox.sh`
7. `run_livox_driver.sh` → `run-jetson-prod-livox-driver.sh` (修复缺失的平台)
8. `run_microdds_agent_jetson.sh` → `run-jetson-prod-microdds-agent.sh`
9. `run_plotjuggler_host.sh` → `run-host-prod-plotjuggler.sh`
10. `run_px4_connector_jetson.sh` → `run-jetson-prod-px4-connector.sh`
11. `run_px4_jetson.sh` → `run-jetson-prod-px4.sh`
12. `run_qgc_jetson.sh` → `run-jetson-prod-qgc.sh`
13. `run_ros2_debug_host.sh` → `run-host-debug-ros2.sh` (注意：调试模式)
14. `run_ros2_debug_jetson.sh` → `run-jetson-debug-ros2.sh` (注意：调试模式)
15. `run_ros2_demo_host.sh` → `run-host-prod-ros2-demo.sh`
16. `run_ros2_jetson.sh` → `run-jetson-prod-ros2.sh`

#### 3. 实施步骤
1. ✅ 创建重命名脚本 `rename_run_scripts.sh`
2. ✅ 更新 AGENTS.md 文档中的命名约定
3. ✅ 检查是否有其他文件引用这些脚本（只有重命名脚本本身引用）
4. ✅ 执行重命名脚本，成功重命名 16 个文件
5. ✅ 验证重命名后的文件列表
6. ✅ 清理重命名脚本

#### 4. 注意事项
- 调试模式脚本需要明确标记为 `debug`
- 生产模式脚本标记为 `prod`
- 保持功能名称的描述性
- 确保所有脚本都有正确的平台后缀

### 优势
1. **明确性**: 模式字段明确区分调试和生产环境
2. **一致性**: 统一的命名模式便于理解和维护
3. **可扩展性**: 未来可以添加其他模式（如 `test`、`staging`）
4. **无歧义**: 避免了双连字符问题

## 结论

用户选择了方案 3，这是一个平衡了明确性和实用性的方案。实施已完成：

1. ✅ 更新了 AGENTS.md 中的命名约定文档
2. ✅ 创建并执行了重命名脚本
3. ✅ 成功重命名了 16 个 run 脚本
4. ✅ 验证了重命名结果

新约定 `run-{platform}-{mode}-{feature}.sh` 已成功实施，提高了代码库的一致性和可维护性。

> **例外说明**: `production.sh` 是一个多服务编排脚本，不遵循单服务命名模式。此外，`host-{action}-{feature}.sh`、`jetson-{action}-{feature}.sh` 以及 `kill_all.sh`、`restart-syncthing.sh` 等工具脚本也不遵循该模式。

**完成状态**: 已完成实施