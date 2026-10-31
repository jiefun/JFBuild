---
name: jbuild
description: 使用当前项目安装的 JFBuild 配置 iOS 打包、归档、导出、上传和补传，或排查 jbuild 执行失败。
---

# JFBuild

项目根目录是本文件所在目录向上三级，与 `Podfile` 同级。执行任务前，先定位本项目实际安装的 JFBuild：

1. 读取项目根目录的 `Pods/Manifest.lock`，缺失时读取 `Podfile.lock`。
2. 查看 `EXTERNAL SOURCES` 中 JFBuild 的 `:path`。有值时按项目根目录解析该路径；没有时使用 `Pods/JFBuild/`。
3. 先读取该组件目录中的 `skills/jbuild/SKILL.md`，再按需要读取 `README.md` 和 `templates/config.yml`，使用当前安装版本的操作说明。

尚未安装或组件路径失效时，先安装项目的 Pod 依赖。打包命令在项目根目录通过 `./jbuild` 执行，配置位于 `jfbuild/config.yml`。
