# JFBuild

iOS 打包与分发工具，支持蒲公英、App Store Connect、Bugly 和钉钉。

## 安装

在 Podfile 中添加：

```ruby
pod 'JFBuild'
```

```bash
pod install
./Pods/JFBuild/jbuild init
```

在 App 项目的 `Podfile` 所在目录执行上述命令。`init` 会生成 `jbuild`、`jfbuild/config.yml` 及材料目录，已有配置会保留。

工程和共享 App Scheme 只有一个时自动填写；有多个候选时写在对应字段上方的注释里，供选择填写。再次执行 `init` 只补充空字段，已有值保留。

初始化后的目录结构：

```text
App项目/
├── Podfile
├── jbuild                  # 命令入口，由 init 生成
├── jfbuild/
│   ├── config.yml          # 配置文件，由 init 生成
│   ├── signing/            # P12 证书、描述文件（.mobileprovision）
│   ├── keys/               # App Store Connect 的 P8 密钥
│   └── tools/              # Bugly 上传工具 JAR
└── build/
    └── jbuild/             # 打包生成的归档、IPA、dSYM 和日志
```

`signing/`、`keys/`、`tools/` 由 `init` 创建，各含一个用于保留空目录的 `.gitkeep`。将所需材料放入对应目录，再在配置中填写路径。`build/jbuild/` 在打包时生成，可加入 `.gitignore`。

工程、Scheme、平台凭证和材料路径都填写在 `jfbuild/config.yml`，字段说明见[配置模板](templates/config.yml)。例如证书放在 `jfbuild/signing/distribution.p12`，`signing.p12` 就填写这个路径。`jfbuild/` 不添加到 App Target 的资源中。

## 使用

```bash
./jbuild
```

输入序号选择任务：

```text
1. 开发包
   归档 → 导出开发 IPA → 上传蒲公英 → 钉钉通知

2. 正式验收包
   清理并归档 → 导出验收 IPA → 上传蒲公英 → 上传 Bugly → 钉钉通知

3. App Store 包
   清理并归档 → 导出商店 IPA → 上传 App Store → 上传 Bugly → 钉钉通知

4. 使用已有归档继续
   选择归档 → 选择从导出或上传开始
```

菜单显示简短步骤状态，选中后列出缺少的配置和跳过原因。

也可以直接指定包类型：

```bash
./jbuild dev
./jbuild release
./jbuild appstore
./jbuild release --desc="修复登录异常"
```

开发包和正式验收包需要更新说明，可交互填写或通过 `--desc` 传入。各包类型的构建配置和导出方式在 `modes` 中设置。

正式验收包和 App Store 包在新归档时先执行 `clean` 清理构建产物；开发包复用编译缓存。使用已有归档或 IPA 继续时不执行清理。

执行时显示当前步骤、编译阶段和已用时间，完成后显示耗时。详细命令日志保存在本次归档目录的 `logs/` 下，按执行顺序和操作名命名，例如 `01_读取工程Scheme.log`、`02_归档.log`。

蒲公英、Bugly、钉钉在配置完整时执行，缺少材料时显示原因并跳过。Bugly 用于 Release 构建。App Store 流程需要有效的 Apple 上传配置，产物上传至 App Store Connect，审核和发布在平台完成。

## 配置

文件路径相对于项目根目录，也支持绝对路径和 `~/`。

| 功能 | 配置内容 |
| --- | --- |
| 工程 | `workspace` 或 `project`，以及共享 `scheme` |
| 签名 | Team ID、P12、密码、描述文件；已安装的签名材料可直接使用 |
| 蒲公英 | API Key、安装方式、安装密码 |
| App Store | Key ID、Issuer ID、P8 文件路径 |
| Bugly | App ID、App Key、官方上传 JAR、classic／pro 类型 |
| 钉钉 | Webhook，按机器人设置填写 Secret 或关键词 |

材料获取入口：[Apple 签名证书](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates)、[Apple 描述文件](https://developer.apple.com/help/account/provisioning-profiles/edit-download-or-delete-profiles/)、[App Store API 密钥](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)、[蒲公英 API](https://www.pgyer.com/doc/view/api)、[Bugly 专业版符号表工具](https://bugly.tds.tencent.com/docs/tutorial/symbol/tool/)、[钉钉群自定义机器人](https://opensource.dingtalk.com/developerpedia/docs/learn/bot/overview/)。

归档需要可用工程、共享 Scheme、构建配置及有效签名；导出 IPA 需要有效归档，以及匹配包类型的签名证书和描述文件。签名已在 Xcode／本机配置好的，可以直接沿用。

`signing.p12` 支持单一路径配合 `p12_password`，或多个 `{path: 文件, password: 密码}` 条目。手动签名时，在 `provisioning_profiles` 中按包类型和 Bundle ID 填写描述文件名称或 UUID。

可使用 `--no-pgyer`、`--no-bugly`、`--no-dingtalk` 跳过本次对应步骤。

## 历史归档

菜单 `4` 按创建时间列出历史记录，包含包类型、版本、构建号、时间和当次归档的更新内容。选中后可重新导出 IPA，或上传该记录中已有的 IPA。

产物和日志默认保存在 `build/jbuild/`。`record.json` 保存归档信息，`result.json` 保存最新执行结果，`results/` 保存历次结果。上传失败后可使用原产物补传。

```yaml
keep_archives: 2
```

此项限制整个项目的有效归档数量。新归档前清理最旧记录，连同其 IPA、dSYM 和日志一起删除；复用已有产物时保留历史记录。失败日志单独保留。

## 更新

```bash
pod update JFBuild
./jbuild config update
```

`Podfile.lock` 记录组件版本，`config_version` 记录配置格式。更新配置时保留已填值，原文件备份为 `config.yml.bak-*`。

## 独立命令

```bash
./jbuild archive --mode=release
./jbuild export --mode=release --archive="App.xcarchive"
./jbuild upload-pgyer --ipa="App.ipa" --desc="更新说明"
./jbuild upload-appstore --ipa="App.ipa"
./jbuild upload-bugly --archive="App.xcarchive"
./jbuild check --ipa="App.ipa"
./jbuild --help
```

## AI 使用

仓库提供 [jbuild Skill](skills/jbuild/SKILL.md)，用于帮助 AI 配置、打包、补传和排错。将 `skills/jbuild/` 安装到所用 AI 工具的技能目录，或让 AI 直接读取该文件。

普通 Pod 安装后，文件位于 `Pods/JFBuild/skills/jbuild/SKILL.md`；`pod install` 不会自动将它安装到 AI 工具中。

## 运行环境

运行环境为 macOS、Xcode、Ruby 和 Python 3；签名证书与钥匙串须已配置。Bugly 上传工具需要 Java。
