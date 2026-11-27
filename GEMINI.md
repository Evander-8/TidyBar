# TidyBar - 极简低内存 macOS 菜单栏图标管理工具
Swift 5.10 + macOS 14.0+ + AppKit + SwiftUI（按需懒加载）+ Carbon + ServiceManagement

<directory>
Sources/TidyBarCore/ - 无界面核心业务逻辑层（数据模型、配置持久化、三段式分区与几何引擎、全局热键、开机自启、系统权限管理）
Sources/TidyBar/ - 纯 AppKit 常驻菜单栏壳、位序守卫、双 EventTap 移动与单图标借位点击转发、开机/重开自动归位引擎、二级下拉栏面板与懒加载 SwiftUI 设置窗口
Resources/ - 应用 Bundle 元数据（Info.plist）与高清图标资源（AppIcon.icns）
Tests/TidyBarTests/ - TidyBarCore 布局引擎、配置存储与热键格式化单元测试
scripts/ - 矢量图标生成、Release 编译签名（.app）与磁盘镜像打包（.dmg）脚本
</directory>

<config>
Package.swift - SwiftPM 双 Target 清单（TidyBarCore + TidyBar），零第三方依赖
Resources/Info.plist - 应用 Bundle 配置（LSUIElement=true、macOS 14.0+、屏幕录制用途说明）
README.md - 项目功能介绍、三段式分区使用指南与源码打包说明
.gitignore - 忽略构建缓存、打包输出与 IDE 用户文件
</config>

[PROTOCOL]: Update this header on change, then check GEMINI.md
