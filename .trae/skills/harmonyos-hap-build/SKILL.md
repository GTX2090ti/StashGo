---
name: "harmonyos-hap-build"
description: "Builds and packages HarmonyOS HAP for this Flutter-OH app, including Linux CLI toolchain bootstrap and engine HAR patches. Invoke when asked to build/package a HAP or re-setup the toolchain."
---

# HarmonyOS HAP 打包

把本仓库（Flutter-OH 应用）编译成鸿蒙 HAP。涵盖 Linux 命令行工具链的搭建、引擎 HAR 补丁、构建与产物校验。

## 何时使用

- 用户要求「打 HAP 包 / 构建鸿蒙包 / 出个 hap」
- `flutter`、`hvigorw`、`ohpm`、`hdc` 命令不存在，或 `/opt/flutter`、`/opt/harmonyos` 缺失
- 构建报 ArkTS 编译错误，错误集中在 `@ohos/flutter_ohos` 的 `OhosAutoFillHelper.ets`

## 关键前提

沙箱里只有 `/workspace` 持久（virtiofs 独立卷），`/opt`、`/root`、apt 安装的包每次重启都会回到基础镜像。因此工具链需要按需重建，安装包缓存在 `/workspace/.toolchain/cache`。

## 步骤

### 1. 检查环境

```bash
source /opt/harmonyos/env.sh 2>/dev/null
flutter --version && hvigorw -v && ohpm -v && hdc -v
```

任一命令缺失或报错，执行第 2 步；否则跳到第 3 步。

### 2. 搭建工具链

```bash
bash /workspace/.toolchain/setup.sh
```

脚本幂等，包含以下动作（无需人工干预）：

1. 安装 JDK 21（`/usr/lib/jvm/java-21-openjdk-amd64`）
2. 解压 HarmonyOS Command Line Tools（默认 6.1.1.268 / API 24）到 `/opt/harmonyos/hos611/command-line-tools`
3. 解压 Flutter-OH 3.35.7+ohos-1.0.5 到 `/opt/flutter`，并补 git 元数据（`git init`、强制跟踪 `bin/internal/engine.version`、打 `3.35.7+ohos-1.0.5` tag）
4. 写 `~/.npmrc`、`~/.ohpm/.ohpmrc`，修补 ohpm 的 axios 代理 bug
5. 生成 `/opt/harmonyos/env.sh` 并追加到 `~/.bashrc`、`~/.zshrc`
6. `flutter precache --ohos`
7. 调用 `patch_ohos_har.py` 修补引擎 HAR

可覆盖变量：`PROXY`、`CACHE_DIR`、`HOS_ROOT`、`CLT_VER`、`CLT_URL`、`FLUTTER_URL`。

### 3. 构建

```bash
source /opt/harmonyos/env.sh
cd /workspace
flutter build hap --release
```

首次约 50 秒，增量更快。构建成功时最后一行是提示配置签名的中文说明，不是错误。

### 4. 校验产物

```bash
H=ohos/entry/build/default/outputs/default/entry-default-unsigned.hap
ls -l "$H" && sha256sum "$H"
unzip -l "$H" | grep -E "modules\.abc|libapp\.so|libflutter\.so"
```

正常产物约 24 MB，包含 `ets/modules.abc`、`libs/arm64-v8a/libapp.so`（release AOT）、`libflutter.so`、`resources/rawfile/flutter_assets/`。

### 5. 发布（用户明确要求时）

按仓库既有命名 `StashScrubber-HarmonyOS-v<version>-unsigned.hap`，版本取自 `pubspec.yaml` 与 `ohos/AppScope/app.json5`：

```bash
cp "$H" "/tmp/StashScrubber-HarmonyOS-v<version>-unsigned.hap"
gh release create "v<version>" --target main --title "<version>" \
  --notes-file /tmp/release_notes.md "/tmp/StashScrubber-HarmonyOS-v<version>-unsigned.hap"
```

发布说明从 `CHANGELOG.md` 对应版本段落整理。

## 已知问题与处理

| 现象 | 原因 | 处理 |
|---|---|---|
| `ohpm install` 报 403 / `The plain http request was sent to https port` | ohpm 内置 axios 在 `proxy` 为 undefined 时自动读取 `HTTPS_PROXY`，与自身 `httpsAgent` 叠加 | 脚本已把 `OhpmRequestInit.js` 的 `proxy:!!this.agent&&void 0` 改为 `&&!1` |
| `Not a valid object name origin/master` | 归档包不含 `.git`，且 `bin/internal/engine.version` 被 gitignore | `git init` + `git add -f bin/internal/engine.version` |
| `Flutter SDK version is 0.0.0-unknown`，依赖解析失败 | 无 git tag，版本推断失败 | `git tag 3.35.7+ohos-1.0.5 <HEAD>` |
| `CompileArkTS` 报 `autoFillManager.AutoFillType` / `requestAutoFill` 不存在 | 引擎用了 API 26 接口，命令行 SDK 最高 API 24 | 运行 `python3 /workspace/.toolchain/patch_ohos_har.py`（改成本地结构镜像 + `ESObject` 动态调用） |
| 构建几秒就失败、日志只有 `BUILD FAILED` | `oh_modules` 为空，依赖没装 | `cd ohos && ohpm install --all` |
| `pubspec.lock` 出现大量改动 | `flutter pub get` 走了国内镜像并受 SDK 固定版本约束 | 构建后 `git checkout -- pubspec.lock`，不要提交 |

## 注意事项

- 产物是 **unsigned**，真机安装前需自行签名（DevEco Studio 的 Signing Configs 或 `hap-sign-tool`）。
- 默认只构建 arm64；要 x64 模拟器包需加 `--target-platform ohos-x64`。
- 不要修改 `ohos/build-profile.json5` 的 `compatibleSdkVersion` 来绕过 API 26 报错，那会改变应用兼容范围。
