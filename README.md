# StashGo（iOS / HarmonyOS 双端）

StashGo 是面向 Stash 媒体库的 Flutter 客户端，兼容 **Stash 0.31.x**。一套 Dart 源码同时构建 **iOS** 与 **HarmonyOS NEXT** 两端。

[English Readme](README_EN.md) | [更新日志 CHANGELOG](CHANGELOG.md) | [iOS 构建说明（中文）](BUILD_IOS_ZH.md) | [iOS Build Guide (EN)](BUILD_IOS_EN.md) —— 安装包在本仓库的 Releases 页下载（iOS 传 IPA、鸿蒙传 HAP，同一 tag）

---

## 仓库结构

| 路径 | 内容 |
|---|---|
| `lib/` | 全部 Dart 业务代码，两端共用 |
| `ios/` | iOS 工程（Runner + Info.plist + Podfile） |
| `ohos/` | HarmonyOS 工程（DevEco 模板：`AppScope/`、`entry/`、hvigor 配置） |
| `codemagic.yaml` | iOS 云端构建配置 |
| `BUILD_IOS_*.md` | iOS 本地构建与 IPA 打包详解 |

自 v1.6.90 起两端源码合并进本仓库；合并前 iOS 与鸿蒙各占一个仓库，`lib/` 靠手工同步，现在只有一份。版本号也统一成单个 build number，两端同增。

## 功能总览

### 短片
- 双排横版卡片：封面、时长、分辨率、收藏星标、字幕角标（检测到外挂字幕显示「字幕」）
- 无限滚动加载，返回保持进入位置，无翻页按钮
- 合并搜索：标题 / 路径 / 详情 + 演员名 + 标签 + 工作室
- 排序：添加时间 / 修改时间 / 标题 / 文件大小 / 时长 / 评分 / 工作室等（0.31.1 新枚举）
- 筛选：评分 / 日期 / 时长 / 收藏 / 工作室 / 演员 / 标签（多选 + 带搜索）
- 多选批量：收藏、评分、标签、合并、生成封面、设置工作室、添加演员、全选（工作室 / 演员 / 标签选择弹窗均带搜索框）
- 详情页：封面（手动设置优先，完整显示不裁切）、信息、演员 / 工作室 / 标签跳转、编辑、削刮、生成封面、收藏、清除全部削刮、文件路径复制
- 演员标签附拍摄时年龄：演员有出生日期就显示「名字 · N 岁」（出生日期只填到年也算），短片没填日期时按去世 / 当前日期推算；没填出生日期则只显示名字
- 文件区：路径单独一行完整显示，附大小 / 时长 / 修改时间；多文件逐块显示，可设为默认文件

### 演员 / 工作室 / 标签
- 卡片列表 + 无限滚动 + 搜索 + 排序；演员 / 工作室竖版卡片（竖屏 3 列）
- 演员详情按「基本信息 / 身体数据 / 职业生涯 / 图像 / 社交 / 档案」分组折叠，收起态显示已填项数；年龄按出生（去世）日期推算，已故显示「N 岁（去世时）」
- 编辑与新建共用全字段折叠表单，保存只提交与原值的差异（清空的字段会真的清掉服务端值）
- **演员合并**：详情页入口，搜索多选源演员并入当前演员，解决重名 / 重复演员
- 工作室详情显示上级 / 子工作室（可跳转）；添加（列表页）/ 删除（详情页，带确认）
- 标签：全部标签浏览 + 带标签的短片；详情页相关短片

### 削刮（元数据刮削）
- 三种模式：片段削刮 / 名称削刮 / URL 削刮
- 源：本地刮削器 + Stash-box（StashDB 等）；片段模式自动用本地演员名搜索 box
- 预览：名称 / 别名 / 出生日期 / 国籍 / 三围 / 从业年限 / 标签 + 图片，「应用并写回」置顶
- 演员削刮默认保留原名；写回兼容 0.31.1（height_cm / alias_list / performer_input）
- 标签与已有工作室不覆盖：写回时标签和本地已有标签取并集（服务端 `tag_ids` 是全量替换语义，合并由客户端完成），本地已挂工作室时保留原工作室
- 写回名字冲突保护：库中已有同名演员时自动跳过名字写入，其余字段照常保存
- 清除全部削刮（短片详情页）：清空简介 / 日期 / 链接 / 工作室 / 演员 / 标签，标题回填文件名（去目录与扩展名）；评分、已看次数与封面不动，需二次确认
- 错误提示中文友好化（404 / 超时 / not implemented / 站点抓取失败）

### 扫描 / 任务 / 生成 / 识别 / 去重
- 扫描：全部或选择二级文件夹，可选生成封面 / 视频预览 / 预览缩略图 / 感知哈希等
- Stash 任务队列：实时显示扫描 / 生成 / 清理任务进度
- 生成封面：详情页单部 / 多选批量 / 任务页全局（0.31.1 metadataGenerate + sceneIDs）
- 生成选项全量支持：标记图像 / 标记截图 / 转码 / 图片感知哈希 / 图片缩略图 / 片段预览等
- **批量识别**：多刮削源（本地刮削器 / Stash-box）按优先级自动匹配短片元数据
- **去重**：按感知哈希距离 + 时长差查找重复短片，多选合并

### 统计 / 插件
- 统计页：短片 / 图片 / 演员 / 工作室 / 标签等媒体库汇总指标
- 插件页：已安装插件列表、启停状态、任务 / 钩子数
- 削刮器包页：已安装包列表、按索引源搜索并多选安装、自动补齐依赖、安装任务进度跟踪、完成后自动重载削刮器

### 服务器与设置
- 多服务器档案（内网 / 外网地址 + API Key，支持路径前缀）+ 工具栏一键切换，按延迟自动选路
- 「测试连接」验证、网络日志、诊断页（档案 / 选路 / 延迟 / Stash 版本）
- 收藏页三子页：短片（已整理）/ 演员（星标）/ 工作室（星标）
- 安全模式：缩略图自动打码，长按临时查看
- 面容解锁：人脸优先，指纹回退（鸿蒙侧走 `local_auth_ohos` 自定义 fork）
- 主题三模式（跟随系统 / 浅色 / 深色）

### 搜索与输入
- 全部搜索栏带清空按钮（短片 / 演员 / 工作室 / 标签 / 筛选 / 合并 / 任务 / 削刮）
- 日期输入自动补全连字符（`20261003` → `2026-10-03`）

## 构建

两端构建通道不同，源码同一份。

产物命名统一为 `StashGo-<iOS|HarmonyOS>-v<版本>-<unsigned|signed>.<ipa|hap>`（如 `StashGo-iOS-v1.6.92-unsigned.ipa`、`StashGo-HarmonyOS-v1.6.92-signed.hap`），Release 附件与归档目录 `archive/{ipa,hap}` 都用这个名字；改名前的历史附件仍用旧的 `StashScrubber-*` 名称。

**iOS** —— 云端 Codemagic（`codemagic.yaml`，`flutter: stable` / `xcode: latest`）。推送 `main` **不会**自动触发构建，需在面板手动触发并轮询。产物为未签名 IPA，本地构建与自签步骤见 [BUILD_IOS_ZH.md](BUILD_IOS_ZH.md)。

```bash
flutter pub get
flutter build ios --release --no-codesign
```

**HarmonyOS** —— 云端 GitHub Actions（`.github/workflows/hap.yml`）：托管 runner 自动下载 HarmonyOS 命令行工具与 Flutter-OH（`.github/actions/setup-harmonyos-toolchain`、`.github/actions/setup-flutter-oh`），无需自托管机器或本机 DevEco Studio。产物为未签名 HAP（`ohos/build-profile.json5` 未配置签名），装机前需自行签名。

```bash
flutter build hap --release --no-codesign
```

本机构建同样需要 DevEco Studio 的 SDK 与 Flutter-OH 工具链。`hvigorw` 的增量判定会在产物齐备时跳过 `flutter assemble`，导致改动的 Dart 不进包，所以先发版走「先 AOT 再打包」两步脚本，而不是直接 `hvigorw assembleHap`。

```bash
flutter pub get
flutter analyze
cd ohos && hvigorw assembleHap -p product=default -p buildMode=release
```

## 安装

**iOS**：未签名 IPA 需自行重签名后侧载（AltStore / Sideloadly / 企业证书）。

**HarmonyOS**：需要 HarmonyOS NEXT（API 18+）。

```bash
hdc install -r StashGo-HarmonyOS-vX.Y.Z-signed.hap     # 覆盖安装保留数据
```

## 版本历史

完整改动记录（按版本倒序，含日期与逐条说明）见 **[CHANGELOG.md](CHANGELOG.md)**；各版本安装包与原始发布说明见 [Releases](https://github.com/GTX2090ti/StashGo/releases)。

- 最新版 **v1.6.96**（2026-10-23）：三语界面、集合浏览、后台批量任务、削刮写回健壮性。
- 版本号规则：iOS 与 HarmonyOS 共用同一个 build number，两端同增。
