<div align="center">

<img src="docs/images/icon.png" width="128" alt="LaunchNew">

# LaunchNew

**おなじみの Launchpad を macOS 26 に。ずっと無料。**

[![Release](https://img.shields.io/github/v/release/baka9981/LaunchNew?style=flat-square&color=0A84FF)](https://github.com/baka9981/LaunchNew/releases/latest)
![macOS](https://img.shields.io/badge/macOS-26%2B-111?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)
[![Downloads](https://img.shields.io/github/downloads/baka9981/LaunchNew/total?style=flat-square&color=34C759)](https://github.com/baka9981/LaunchNew/releases)
[![License](https://img.shields.io/badge/license-MIT-8E8E93?style=flat-square)](LICENSE)
[![Website](https://img.shields.io/badge/%E5%85%AC%E5%BC%8F%E3%82%B5%E3%82%A4%E3%83%88-baka9981.github.io-0A84FF?style=flat-square&logo=safari&logoColor=white)](https://baka9981.github.io/LaunchNew/)

<a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a>

🌐 <a href="https://baka9981.github.io/LaunchNew/"><b>公式サイト</b></a>

<img src="docs/images/whats-new.png" width="49%" alt="新機能"> <img src="docs/images/guide.png" width="49%" alt="ようこそガイド">

</div>

## なぜ作ったか

macOS 26 では Launchpad が「アプリ」ウインドウに置き換わりました。LaunchNew は、ページ、フォルダ、ドラッグで並べ替え、入力して検索といったおなじみのフルスクリーングリッドを取り戻し、Launchpad になかった機能も加えます。

## 機能

| | |
|---|---|
| 🚀 **Launchpad そのまま** | ぼかし背景のフルスクリーングリッド、ページ、フォルダ、編集モード。⌥Space / F4 / トラックパッドのピンチ / ホットコーナーで開く |
| 🔎 **賢い検索** | ピンイン・頭文字、別名、`#タグ`、スマートフォルダ。計算や単位換算（`128*3`、`5 km in mi`）も |
| 📂 **ファイルをアイコンにドロップ** | Dock と同じく、ファイルを App のアイコンにドロップするとその App で開く |
| 🧩 **カスタム項目** | Web サイト、ファイル、フォルダ、スクリプトを App のように配置 |
| 🎨 **自分好みに** | アイコン変更、好きな背景画像、アイコンサイズ、アニメーション速度、ダークモード（Mac に合わせ、App 自身のダークアイコンを使用）、Liquid Glass のフォルダと検索バー、ウインドウ／フルスクリーン、行数・列数。縦向きのディスプレイではグリッドも縦に |
| 🗂 **レイアウト** | 仕事用と趣味用でページを分け、メニュー・リンク・ショートカットで切り替え |
| 🔔 **リアルタイム表示** | Dock の通知バッジ、起動中インジケータ、最近使った App の列（⌘1〜⌘9 で開く、右クリックで固定） |
| 🧹 **きれいにアンインストール** | `~/Library` の残りファイルもまとめてゴミ箱へ |
| 🕸 **長く開いていない App** | 3か月以上開いていない App を薄く表示、またはまとめて選択してフォルダへ移動・非表示 |
| 🔒 **プライバシー** | Touch ID で App を隠す、レイアウトの自動バックアップ、iCloud 同期（任意） |
| ⚡️ **ショートカットとリンク** | フォルダを開く、検索、レイアウト切り替え。`launchnew://` に対応 |
| 🔄 **自動アップデート** | Sparkle による署名付きアップデート |

## インストール

1. [最新リリース](https://github.com/baka9981/LaunchNew/releases/latest) から **LaunchNew-x.y.z.dmg** をダウンロードして開き、LaunchNew を「アプリケーション」にドラッグします。
2. 初回起動時に開発元を確認できないと表示されたら、**システム設定 › プライバシーとセキュリティ** で **このまま開く** をクリックします。
3. **⌥Space** で開きます。何もないところを右クリックするか **⌘,** で設定を開きます。

macOS 26 以降が必要です。

## ソースからビルド

```bash
git clone https://github.com/baka9981/LaunchNew.git
cd LaunchNew
./scripts/run.sh
```

テスト、デバッグ、リリースについては [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) を参照してください。

## プライバシー

アカウントも解析もなく、アップデートの確認以外に通信しません。レイアウトは `~/Library/Application Support/LaunchNew` に保存され、他の App のデータ（システムの Launchpad データベースを含む）は読み取るだけで書き込みません。唯一の例外は、「編集…」で「Dockに追加」を押したときに、その App を Dock に追加することです。

## 無料

LaunchNew は完全に無料です。Pro 版、サブスクリプション、広告はありません。


## ライセンス

[MIT](LICENSE)
