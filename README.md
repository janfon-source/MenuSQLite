# 隨手庫 MenuSQLite

住在 macOS 選單列的輕量 SQLite 管理工具。點一下選單列圖示就能查資料、改資料、跑 SQL，按 Esc 就收起來。

A lightweight SQLite manager that lives in the macOS menu bar. [English below](#english).

## 功能

- **開啟與建立**：開啟任何 SQLite 資料庫（不限副檔名，依檔案內容判斷），或新增一個空的資料庫。記住最近開過的資料庫，下次啟動自動開回上次那個。
- **與執行中的程式共用**：資料庫正被其他程式使用時（例如 Node.js 的 better-sqlite3），遇到寫入鎖定會最多等 5 秒，而不是立刻顯示「database is locked」。WAL 模式的資料庫也能正常讀寫。
- **伺服器上的資料庫（SSH）**：輸入主機（`user@host` 或 `~/.ssh/config` 裡的 Host）、資料庫路徑，必要時加上連接埠和私鑰，就能操作伺服器上的 SQLite 檔案。透過 SSH 在伺服器上執行 `sqlite3`，直接讀寫那個檔案，不會下載或上傳整個資料庫；共用同一條 SSH 連線，第一次之後的操作都很快。用 SSH 金鑰或 ssh-agent 登入（不會詢問密碼），伺服器需要裝有 `sqlite3`。檔案沒有寫入權限時自動以唯讀開啟。主機欄位的下拉選單列出 `~/.ssh/config` 裡的 Host，選了就自動填入連接埠、私鑰和上次在那台主機用過的資料庫路徑。
- **瀏覽資料**：左側列出資料表和視圖，右側表格顯示資料，點欄位標題排序，每頁 200 列可翻頁。NULL 和 BLOB 以淡色顯示。
- **直接編輯**：按兩下儲存格修改，右鍵可設為 NULL；狀態列的 ＋／− 按鈕新增或刪除資料列（刪除前會確認）。視圖和 `WITHOUT ROWID` 資料表為唯讀。
- **新增與編輯資料表**：左側清單下方的 ＋／鉛筆／垃圾桶按鈕，或在資料表上按右鍵。在表格裡設定每個欄位的名稱、類型、主鍵、非空、唯一和預設值，可新增、刪除、上下移動欄位、重新命名資料表；下方即時顯示將執行的 SQL，以及會刪除哪些欄位資料等提醒。只改名稱或在最後新增欄位時直接 ALTER TABLE；其他變更以「建新表、搬資料、換名字」的方式在交易中完成（舊版 SQLite 也適用），失敗時整個還原。外鍵、CHECK 限制和觸發程序在重建時不會保留，會事先提醒。
- **新增與編輯視圖**：＋ 按鈕選「新增視圖…」，或在視圖上按右鍵／鉛筆按鈕編輯。輸入名稱、選填的欄位名稱和 SELECT 語句，按「預覽結果」（⌘↩）先看前 50 列。儲存前會先執行一次 SELECT，有錯（例如資料表或欄位不存在）就顯示錯誤、不會存檔。SQLite 沒有 ALTER VIEW，編輯時在交易中刪除舊視圖再建立新的；視圖上的觸發程序會因此刪除，會事先提醒。
- **結構**：欄位（類型、非空、預設值、主鍵）、索引、資料列數，以及有語法上色的 CREATE 語句。
- **執行 SQL**：語法上色的編輯器，⌘↩ 執行；有選取文字時只執行選取的部分，可一次執行多個語句。顯示結果、影響列數、耗時或錯誤訊息。
- **結構文件（Markdown）**：工具列的文件按鈕或 ⇧⌘D，把目前資料庫所有資料表和視圖的結構整理成一份 Markdown：欄位（類型、非空、唯一、預設值、主鍵）、外鍵、索引、觸發程序、資料列數和建立語句，表格已對齊，純文字也好讀。文件在獨立視窗開啟，可先修改內容，再「另存新檔…」（⌘S）或「用預設 App 開啟」（例如隨手記）；「重新產生」依資料庫最新狀態重做。
- **匯出 CSV**：SQL 分頁匯出查詢結果，其他分頁匯出整個資料表。UTF-8 含 BOM，Excel 開啟中文不會亂碼。
- **拷貝**：選取資料列按 ⌘C，以 Tab 分隔拷貝，可直接貼到試算表。
- **繁體中文 / English 介面**、淺色／深色主題、釘選視窗、登入時自動開啟。

| 快捷鍵 | 功能 |
|---|---|
| ⌘O / ⌘N | 開啟 / 新增資料庫 |
| ⇧⌘O | 連線到伺服器上的資料庫 |
| ⌘R | 重新整理 |
| ⌥⌘N / ⌥⇧⌘N | 新增資料表 / 新增視圖 |
| ⌥⌘E | 編輯選取的資料表或視圖 |
| ⇧⌘D | 結構文件（Markdown） |
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

## 連線到伺服器的需求

透過 SSH 開啟伺服器上的資料庫時，需要：

- 用 **SSH 金鑰或 ssh-agent** 登入伺服器（隨手庫不會詢問密碼）。
- 伺服器上裝有 **`sqlite3` 指令**。

隨手庫連線時會自動檢查，沒有 `sqlite3` 會直接提示。也可以在終端機手動確認：

```sh
ssh 主機名稱 'command -v sqlite3 && sqlite3 -version'
```

有安裝會印出路徑和版本（例如 `/usr/bin/sqlite3`、`3.45.1 …`），沒有安裝則什麼都不會印。主機名稱可以用 `~/.ssh/config` 裡的 Host。

沒有安裝時，依伺服器的系統安裝（需要 sudo 權限）：

| 系統 | 安裝指令 |
|---|---|
| Ubuntu / Debian | `sudo apt install sqlite3` |
| RHEL / CentOS / Rocky / Alma | `sudo dnf install sqlite`（舊版用 `yum`） |
| Alpine | `sudo apk add sqlite` |
| macOS | 內建，不用安裝 |

舊版的 `sqlite3`（例如 CentOS 7 內建的 3.7.17）也可以使用：隨手庫會自動偵測，改用 CSV 格式取得資料。這時以文字存放的數字會顯示成數字（只影響對齊），BLOB 欄位無法正確顯示。

**權限**：隨手庫用 SSH 登入的帳號讀寫檔案。要修改資料，這個帳號需要檔案和所在資料夾的寫入權限（SQLite 修改時會在同一個資料夾建立暫存檔），否則會以唯讀開啟。找不到檔案或沒有權限進入資料夾時，錯誤訊息會註明登入的帳號和主機，以及同一個資料夾裡的資料庫檔案。

---

## English

### Features

- **Open and create** any SQLite database (recognized by its contents, whatever the extension), or a new empty one. Recent databases are remembered, and the last one reopens at launch.
- **Shared with running apps**: when another program is using the database (a Node.js app with better-sqlite3, say), MenuSQLite waits up to 5 seconds for its lock instead of failing at once with "database is locked". WAL-mode databases work as usual.
- **Databases on servers (SSH)**: give the server (`user@host`, or a Host in `~/.ssh/config`) and the database's path, with a port and key if needed, to work on an SQLite file on a server. MenuSQLite runs `sqlite3` there over SSH, so the file stays where it is and is never copied back and forth; one shared SSH connection keeps later steps quick. Signs in with SSH keys or ssh-agent (it never asks for a password), and the server needs `sqlite3`. A file without write permission opens read-only. The server field lists the Hosts in `~/.ssh/config`; picking one fills in its port, key and the database path last used there.
- **Browse** tables and views on the left and their rows on the right; click a header to sort; 200 rows a page. NULLs and BLOBs show dimmed.
- **Edit in place**: double-click a cell to change it, or right-click to set it to NULL; add or delete rows with ＋ / − in the status bar (deleting asks first). Views and `WITHOUT ROWID` tables are read-only.
- **Create and edit tables** with the ＋ / pencil / trash buttons under the list, or by right-clicking a table. Set each column's name, type, primary key, not null, unique and default in a grid; add, remove and reorder columns and rename the table, with the SQL to run shown live below, along with warnings such as which columns' data would be deleted. Renaming the table or adding columns at the end uses ALTER TABLE; other changes rebuild the table (new table, copy rows, swap names) in a transaction, which works on old SQLite too and undoes everything if a step fails. Foreign keys, CHECK constraints and triggers aren't kept through a rebuild, and you're told beforehand.
- **Create and edit views**: choose New View… from the ＋ button, or right-click a view (or use the pencil) to edit it. Enter a name, optional column names and the SELECT, and click Preview (⌘↩) to see its first 50 rows. Saving runs the SELECT first and refuses with the error if it fails (a missing table or column, say). SQLite has no ALTER VIEW, so an edit drops the view and creates it again in a transaction; triggers on the view are deleted, and you're told beforehand.
- **Structure**: columns (type, not null, default, primary key), indexes, row count and the syntax-colored CREATE statement.
- **Run SQL** in a syntax-colored editor with ⌘↩; with text selected, only the selection runs, and several statements can run at once. Shows the results, rows changed, time taken or the error.
- **Structure document (Markdown)**: the document button in the toolbar, or ⇧⌘D, writes the structure of every table and view as one Markdown document: columns (type, not null, unique, default, primary key), foreign keys, indexes, triggers, row counts and CREATE statements, with tables lined up so the plain text reads well too. It opens in its own window, where you can edit it, then Save As… (⌘S) or Open in Default App; Regenerate makes it again from the database as it is now.
- **Export CSV**: the query's results on the SQL tab, the whole table otherwise. UTF-8 with a BOM, so Excel reads Chinese correctly.
- **Copy** selected rows with ⌘C as tab-separated text, ready to paste into a spreadsheet.
- **Traditional Chinese / English UI**, light or dark theme, pinning, and an option to open at login.

### Install

Requires macOS 13 or later and Xcode or the Command Line Tools (`xcode-select --install`).

```sh
./build.sh install   # builds and installs /Applications/隨手庫.app
```

Run `./build.sh` alone to build into `build/隨手庫.app` without installing.

### Requirements for databases on servers

Opening a database on a server over SSH needs:

- Sign-in with **SSH keys or ssh-agent** (MenuSQLite never asks for a password).
- The **`sqlite3` command** on the server.

MenuSQLite checks when it connects and says so if `sqlite3` is missing. To check by hand:

```sh
ssh server 'command -v sqlite3 && sqlite3 -version'
```

If it's installed, this prints its path and version (such as `/usr/bin/sqlite3` and `3.45.1 …`); if not, nothing. The server can be a Host from `~/.ssh/config`.

To install it (with sudo):

| System | Command |
|---|---|
| Ubuntu / Debian | `sudo apt install sqlite3` |
| RHEL / CentOS / Rocky / Alma | `sudo dnf install sqlite` (`yum` on older releases) |
| Alpine | `sudo apk add sqlite` |
| macOS | Built in |

Old `sqlite3` versions (such as 3.7.17 on CentOS 7) work too: MenuSQLite notices and reads CSV output instead. Numbers stored as text then show as numbers (only their alignment differs), and BLOB columns can't be shown properly.

**Permissions**: MenuSQLite reads and writes as the SSH account. Changing data needs write permission on the file and its folder (SQLite writes a journal beside it); otherwise the database opens read-only. When a file can't be found or a folder can't be entered, the error names the account and server, and lists the database files in the folder.

## License

[MIT](LICENSE) © 2026 Jeff Lee
