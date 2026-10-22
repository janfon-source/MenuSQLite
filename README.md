# 隨手庫 MenuSQLite

住在 macOS 選單列的輕量 SQLite 管理工具。點一下選單列圖示就能查資料、改資料、跑 SQL，按 Esc 就收起來。

A lightweight SQLite manager that lives in the macOS menu bar. [English below](#english).

## 功能

- **開啟與建立**：開啟任何 SQLite 資料庫（不限副檔名，依檔案內容判斷），或新增一個空的資料庫。記住最近開過的資料庫，下次啟動自動開回上次那個。
- **伺服器上的資料庫（SSH）**：輸入主機（`user@host` 或 `~/.ssh/config` 裡的 Host）、資料庫路徑，必要時加上連接埠和私鑰，就能操作伺服器上的 SQLite 檔案。透過 SSH 在伺服器上執行 `sqlite3`，直接讀寫那個檔案，不會下載或上傳整個資料庫；共用同一條 SSH 連線，第一次之後的操作都很快。用 SSH 金鑰或 ssh-agent 登入（不會詢問密碼），伺服器需要裝有 `sqlite3`。檔案沒有寫入權限時自動以唯讀開啟。主機欄位的下拉選單列出 `~/.ssh/config` 裡的 Host，選了就自動填入連接埠、私鑰和上次在那台主機用過的資料庫路徑。
- **瀏覽資料**：左側列出資料表和視圖，右側表格顯示資料，點欄位標題排序，每頁 200 列可翻頁。NULL 和 BLOB 以淡色顯示。
- **直接編輯**：按兩下儲存格修改，右鍵可設為 NULL；狀態列的 ＋／− 按鈕新增或刪除資料列（刪除前會確認）。視圖和 `WITHOUT ROWID` 資料表為唯讀。
- **結構**：欄位（類型、非空、預設值、主鍵）、索引、資料列數，以及有語法上色的 CREATE 語句。
- **執行 SQL**：語法上色的編輯器，⌘↩ 執行；有選取文字時只執行選取的部分，可一次執行多個語句。顯示結果、影響列數、耗時或錯誤訊息。
- **匯出 CSV**：SQL 分頁匯出查詢結果，其他分頁匯出整個資料表。UTF-8 含 BOM，Excel 開啟中文不會亂碼。
- **拷貝**：選取資料列按 ⌘C，以 Tab 分隔拷貝，可直接貼到試算表。
- **繁體中文 / English 介面**、淺色／深色主題、釘選視窗、登入時自動開啟。

| 快捷鍵 | 功能 |
|---|---|
| ⌘O / ⌘N | 開啟 / 新增資料庫 |
| ⇧⌘O | 連線到伺服器上的資料庫 |
| ⌘R | 重新整理 |
| ⌘1 / ⌘2 / ⌘3 | 資料 / 結構 / SQL 分頁 |
| ⌘↩ | 執行 SQL |
| ⇧⌘E | 匯出 CSV |
| ⌘C | 拷貝選取的資料列 |
| Esc | 收起視窗 |

## 安裝

需要 macOS 13 以上，以及 Xcode 或 Command Line Tools（`xcode-select --install`）。

```sh
./build.sh install   # 編譯並安裝到 /Applications/隨手庫.app
```

只想編譯不安裝就執行 `./build.sh`，結果在 `build/隨手庫.app`。

---

## English

### Features

- **Open and create** any SQLite database (recognized by its contents, whatever the extension), or a new empty one. Recent databases are remembered, and the last one reopens at launch.
- **Databases on servers (SSH)**: give the server (`user@host`, or a Host in `~/.ssh/config`) and the database's path, with a port and key if needed, to work on an SQLite file on a server. MenuSQLite runs `sqlite3` there over SSH, so the file stays where it is and is never copied back and forth; one shared SSH connection keeps later steps quick. Signs in with SSH keys or ssh-agent (it never asks for a password), and the server needs `sqlite3`. A file without write permission opens read-only. The server field lists the Hosts in `~/.ssh/config`; picking one fills in its port, key and the database path last used there.
- **Browse** tables and views on the left and their rows on the right; click a header to sort; 200 rows a page. NULLs and BLOBs show dimmed.
- **Edit in place**: double-click a cell to change it, or right-click to set it to NULL; add or delete rows with ＋ / − in the status bar (deleting asks first). Views and `WITHOUT ROWID` tables are read-only.
- **Structure**: columns (type, not null, default, primary key), indexes, row count and the syntax-colored CREATE statement.
- **Run SQL** in a syntax-colored editor with ⌘↩; with text selected, only the selection runs, and several statements can run at once. Shows the results, rows changed, time taken or the error.
- **Export CSV**: the query's results on the SQL tab, the whole table otherwise. UTF-8 with a BOM, so Excel reads Chinese correctly.
- **Copy** selected rows with ⌘C as tab-separated text, ready to paste into a spreadsheet.
- **Traditional Chinese / English UI**, light or dark theme, pinning, and an option to open at login.

### Install

Requires macOS 13 or later and Xcode or the Command Line Tools (`xcode-select --install`).

```sh
./build.sh install   # builds and installs /Applications/隨手庫.app
```

Run `./build.sh` alone to build into `build/隨手庫.app` without installing.

## License

[MIT](LICENSE) © 2026 Jeff Lee
