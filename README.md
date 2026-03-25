# この配布物には、やねうら王本体および評価関数ファイルは含まれていません。
  初回起動時に、利用者の環境で公開配布元から自動ダウンロードしてセットアップします。
  各ファイルのライセンス・権利関係は配布元の案内をご確認ください。


# ローカル外部やねうら王ブリッジ

このフォルダは、FiveM の将棋 AI 対局用に **ローカルのやねうら王 EXE** を起動するブリッジです。

この公開版は **engine 本体を同梱しません**。  
代わりに、`START_LOCAL_YANEOURAOU_BRIDGE.cmd` を押すと、初回だけ必要な engine と eval を自動ダウンロードして設定します。

## できること

- ワンクリックで初回セットアップ
- 初回に engine 本体と eval を自動ダウンロード
- 無料で強い eval を優先取得
  - 第1候補: **Hao 系**
  - 失敗時フォールバック: **水匠5 (Suisho5)**
- 手元の PC で起動確認を行い、使える実行ファイルを自動選択
- 2回目以降は再ダウンロードせず再利用

## 動作環境

### 対応 OS
- Windows 10 / 11
- Windows Server 2016 以降

### 必要なもの
- インターネット接続
- PowerShell

### PowerShell について
- **Windows PowerShell 5.1** は、Windows 10 以降のクライアントと Windows Server 2016 以降で既定インストールです。
- **PowerShell 7** は別製品で、Windows PowerShell 5.1 を置き換えず、並行インストールされます。
- この公開版のワンクリック起動は、`powershell.exe` を優先し、見つからない場合は `pwsh` を試します。

## いちばん簡単な使い方

1. ZIP を解凍する
2. `START_LOCAL_YANEOURAOU_BRIDGE.cmd` をダブルクリックする
3. 初回だけ自動セットアップが始まる
4. 完了後、自動で `http://127.0.0.1:18777/` で待機する
5. FiveM 側で AI対戦が行えます。

## 初回セットアップで行うこと

1. やねうら王本体を GitHub Releases から取得
2. 評価関数を自動取得
   - 第1候補: Hao 系
   - 失敗時フォールバック: 水匠5
3. 7z の展開ツールが無ければ補助ツールを取得
4. ローカル PC で engine の起動確認を行う
5. 成功した組み合わせを `engine` 配下に保存
6. `bridge_config.json` の `fvScale` を自動調整

## 2回目以降の起動

次のファイルが残っていれば、通常は再ダウンロードしません。

- `engine\\yaneuraou.exe`
- `engine\\eval\\nn.bin`
- `engine\\MATCHING_ENGINE_VERIFIED.txt`

## フォルダ構成

- `START_LOCAL_YANEOURAOU_BRIDGE.cmd`  
  ワンクリック起動用
- `INSTALL_MATCHING_YANEOURAOU_EXE.ps1`  
  初回セットアップ本体
- `bridge_server.ps1`  
  ローカル HTTP ブリッジ本体
- `bridge_config.json`  
  動作設定
- `engine\\yaneuraou.exe`  
  使う engine 本体
- `engine\\eval\\nn.bin`  
  使う評価関数
- `TEST_ENGINE_DIRECT.ps1`  
  直接起動テスト
- `TEST_ENGINE_EVALDIR_PROBE.ps1`  
  EvalDir を含めた確認用テスト

## 手動インストールしたいとき

自動セットアップが失敗した場合や、自分で engine / eval を選びたい場合は、手動で配置できます。

### 手動インストールの流れ

1. この ZIP を解凍する
2. やねうら王本体を手動でダウンロードして解凍する
3. `engine\\yaneuraou.exe` に使いたい実行ファイルを置く
4. 評価関数を手動でダウンロードして `engine\\eval\\nn.bin` に置く
5. 必要なら `bridge_config.json` の `fvScale` と `displayName` を調整する
6. `START_LOCAL_YANEOURAOU_BRIDGE.cmd` を起動する

### 手動インストール時のおすすめ

#### engine 本体
- まずは **Windows 64bit 版** をダウンロードしてください。
- 解凍後に複数の exe が入っている場合は、通常は **AVX2 系** から試すのが無難です。
- CPU 命令に合わない exe を使うと起動しないことがあります。

#### eval
- **水匠5** を使う場合は、配布アーカイブを解凍して `nn.bin` を取り出します。
- **Hao 系** を使う場合は、配布元の案内に従って `nn.bin` を入手し、同じく `engine\\eval\\nn.bin` に置いてください。
- engine と eval の型が合わないと起動に失敗します。

### 手動インストール後の配置場所

- engine 本体: `engine\\yaneuraou.exe`
- eval: `engine\\eval\\nn.bin`

### 手動インストール後にやること

手動で差し替えたあと、古い検証結果が残っていると判定がずれることがあるので、次のファイルを削除してから起動してください。

- `engine\\MATCHING_ENGINE_VERIFIED.txt`
- `INSTALL_MATCHING_YANEOURAOU_EXE_RESULT.txt`

## AI の強さを変えたいとき

基本設定は `bridge_config.json` です。

```json
{
  "threads": 1,
  "hashMb": 64,
  "multiPv": 1,
  "fvScale": 20,
  "displayName": "ローカルやねうら王"
}
```

### 主な項目
- `threads`  
  探索スレッド数です。増やすと強くなることがありますが、CPU 使用率も上がります。
- `hashMb`  
  探索用メモリです。増やすと多少有利になることがありますが、メモリ使用量も増えます。
- `multiPv`  
  複数候補手の数です。通常は `1` のままで十分です。
- `fvScale`  
  評価関数に合わせる値です。eval を差し替えたら見直してください。
- `displayName`  
  UI やログに出す表示名です。

### 強くしたい場合の例
- `threads`: 2 ～ 4
- `hashMb`: 128 ～ 512
- `multiPv`: 1

まずは `threads=2`, `hashMb=256`, `multiPv=1` あたりが扱いやすいです。

## 水匠5 以外の eval / engine を使いたいとき

### 配置場所
- engine 本体: `engine\\yaneuraou.exe`
- eval: `engine\\eval\\nn.bin`

### 手動差し替えの手順
1. ブリッジを終了する
2. `engine\\yaneuraou.exe` を差し替える
3. `engine\\eval\\nn.bin` を差し替える
4. 必要なら `bridge_config.json` の `fvScale` と `displayName` を直す
5. 次のファイルを削除する
   - `engine\\MATCHING_ENGINE_VERIFIED.txt`
   - `INSTALL_MATCHING_YANEOURAOU_EXE_RESULT.txt`
6. `START_LOCAL_YANEOURAOU_BRIDGE.cmd` をもう一度起動する

### 注意点
- engine と eval の型が合わないと起動に失敗します。
- eval を差し替えたときは、`fvScale` も合わせてください。
- うまく動かないときは `TEST_ENGINE_EVALDIR_PROBE.ps1` で確認できます。

### この公開版の既定値
- Hao 系: `fvScale=20`
- 水匠5: `fvScale=24`

## 失敗したときの確認先

- `INSTALL_MATCHING_YANEOURAOU_EXE_RESULT.txt`
- `C:\\Users\\adazi\\Downloads\\powershell` の最新 `.txt`
- Windows Defender / SmartScreen で exe が止められていないか

## PowerShell 5 以外の環境でも使えるか

### Windows + PowerShell 7
使えます。  
この公開版は `powershell.exe` が無い場合に `pwsh` を試します。

### Windows 以外
この版は **非対応** です。  
理由は次の通りです。
- 起動が `.cmd` 前提
- ダウンロード対象が Windows 用やねうら王 EXE
- パスや展開手順が Windows 前提

macOS や Linux での導入手順は、この ZIP には含めていません。

## リンク集

### やねうら王関連
- やねうら王 GitHub  
  https://github.com/yaneurao/YaneuraOu
- やねうら王 Releases  
  https://github.com/yaneurao/YaneuraOu/releases
- やねうら王のインストール手順  
  https://github.com/yaneurao/YaneuraOu/wiki/%E3%82%84%E3%81%AD%E3%81%86%E3%82%89%E7%8E%8B%E3%81%AE%E3%82%A4%E3%83%B3%E3%82%B9%E3%83%88%E3%83%BC%E3%83%AB%E6%89%8B%E9%A0%86
- やねうら王 Wiki トップ  
  https://github.com/yaneurao/YaneuraOu/wiki

### 評価関数関連
- 水匠5 評価関数ファイル単体の公開先  
  https://github.com/yaneurao/YaneuraOu/releases
- Hao 系の公開情報例  
  https://github.com/YuaHyodo/Haojian_nnue

### PowerShell 関連
- Windows PowerShell 5.1 について  
  https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_windows_powershell_5.1?view=powershell-5.1
- PowerShell 7 を Windows にインストールする  
  https://learn.microsoft.com/ja-jp/powershell/scripting/install/install-powershell-on-windows?view=powershell-7.6

## 補足

- この版では `yaneuraou_engine` リソースは使いません。
- AI 対局はローカル外部やねうら王 EXE 専用です。
- ログは `C:\\Users\\adazi\\Downloads\\powershell` に `.txt` で出ます。

## 外部AI利用について

- このリポジトリの外部AI機能は、ローカル環境で将棋AIを起動し、AI対局時のみ利用することを目的としています。
FiveM / GTA クライアントそのものを書き換えたり、メモリへ注入したり、他プレイヤーに対して不正な優位を与える用途は想定していません。

FiveM / RedM の公式案内では、グローバルBANの対象として、ゲームクライアントへ情報を注入しようとする違反外部プログラムが挙げられています。
一方で、外部アプリ全般について一律に安全保証がされているわけでもありません。

このため、本機能は「AI対局専用」「非注入」「非改変」の前提で設計していますが、利用環境や他ツールとの干渉まで含めて完全な無リスクを保証するものではありません。
利用する場合は、自己責任で、不要な外部ツールを併用せず、AI対局用途のみに限定してください。

なお、Rockstar は Community RP Server 利用時には Community Server launcher 側で BattlEye が無効化される旨を案内しています。
ただし、これは本ツールの安全性を保証するものではなく、最終的な判断は Rockstar / Cfx.re 側のポリシーに従います。

補足
本ツールは AI対局用途のみを想定しています。
人間同士の対局、戦闘補助、操作自動化、不正行為目的での使用はしないでください。
FiveM / GTA クライアントへの注入や改変を行う他ツールとの併用は避けてください。
利用にあたっては、Rockstar および Cfx.re の最新ポリシーを確認してください。

参考情報
Rockstar Games Community Guidelines
Rockstar Creator Platform License Agreement
FiveM / RedM Community Server Ban FAQ
Rockstar GTA Online / Community RP 関連サポート情報


## ライセンスと配布について

このリポジトリは、ローカルAI対局用の bridge / installer / 設定ファイルを配布するものです。
やねうら王本体（実行ファイル）および評価関数ファイル（nn.bin など）は、このリポジトリには同梱していません。

必要なファイルは、初回起動時に利用者のPC上で公開配布元から自動取得されます。
取得されるやねうら王本体および評価関数ファイルの著作権・配布条件・ライセンスは、それぞれの配布元に従います。

やねうら王本体のライセンスは公式リポジトリ上で GPL-3.0 とされています。
本リポジトリは upstream 配布物の再配布を目的とするものではありません。

## Notice

This repository distributes only the launcher, bridge scripts, configuration files, and installation helpers.
Executable engine binaries and evaluation files are not bundled in this repository.

On first launch, required files are downloaded directly on the end user's machine from their respective public distribution sources.
All rights, license terms, and redistribution conditions for YaneuraOu and any evaluation files remain subject to their original upstream licensors and distribution pages.
