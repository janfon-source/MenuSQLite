# MenuSQLite 隨手SQLite

A lightweight SQLite manager that lives in the macOS menu bar. Click the menu bar icon to look things up, change data and run SQL; press Esc to put it away.

住在 macOS 選單列的輕量 SQLite 管理工具。[中文說明在下方](#中文說明)。

## Features

- **Open and create** any SQLite database (recognized by its contents, whatever the extension), or a new empty one. Recent databases are remembered, and the last one reopens at launch.
- **Shared with running apps**: when another program is using the database (a Node.js app with better-sqlite3, say), MenuSQLite waits up to 5 seconds for its lock instead of failing at once with "database is locked". WAL-mode databases work as usual.
- **Databases on servers (SSH)**: give the server (`user@host`, or a Host in `~/.ssh/config`) and the database's path, with a port and key if needed, to work on an SQLite file on a server. MenuSQLite runs `sqlite3` there over SSH, so the file stays where it is and is never copied back and forth; one shared SSH connection keeps later steps quick. Signs in with SSH keys or ssh-agent (it never asks for a password), and the server needs `sqlite3`. A file without write permission opens read-only. The server field lists the Hosts in `~/.ssh/config`; picking one fills in its port, key and the database path last used there.
- **Several databases at once, in tabs**: each database you open (from the folder button, a favorite, the recent list or Finder) opens in a tab of its own under the toolbar, named after its favorite when it’s one, or else its file (hover for where it is). Click a tab to switch (⌃Tab / ⌃⇧Tab go to the next and previous), drag one along the strip to reorder them; each keeps its table, page, sort, filter, SQL and results as you left them. The same database can be open in several tabs, numbered (2), (3)… × or ⌥⌘W closes a tab; ＋ opens a database in a new one.
- **Favorite databases** (the star button): open a favorite in one click. “Add This Database to Favorites…” (⌘D) keeps the database open now (a file, or one on a server) under a name of your own; “Manage Favorite Databases…” lists them to add, duplicate, edit and delete, drag into order, and open (double-click or Open).
- **Browse** tables and views on the left and their rows on the right; click a header to sort; 200 rows a page. NULLs and BLOBs show dimmed.
- **Filter rows** with the filter button above the rows (⌥⌘F): pick a column, a comparison (`=`, `!=`, `>`, `<`, `>=`, `<=`, `LIKE`, `NOT LIKE`, `IS NULL`, `IS NOT NULL`, `IS EMPTY`, `IS NOT EMPTY`) and a value, and add more conditions joined by AND or OR. The row count and paging follow the filter, and the SQL tab starts with the matching SELECT (with the sort too) until you edit it yourself.
- **Choose the columns to show** (the checklist button beside the filter, or ⌥⌘K): a checkbox for each column; untick one to hide it, and the menu stays open for the next. All columns show to begin with, and “Show All” brings them back. Each table remembers its choice while the app runs; the status line says how many are hidden, ⌘C copies only the columns shown, and the SQL tab’s SELECT lists them.
- **Reload the rows** (the arrow button under the rows): reads the page showing again, keeping the filter, sort and page, for rows another program or the SQL tab has changed.
- **Export what the Data tab shows** (the share button under the rows): every row the filter lets through, in the sort shown and only the columns showing, to a CSV file, however many rows there are (not just the page of 200). The same button under the SQL tab exports its results: the SELECT written to match the Data tab is run again without its LIMIT 100, and your own SQL's results are written as they show (it isn't run again, as it may change data).
- **Edit in place**: double-click a cell to change it, or right-click to set it to NULL; add or delete rows with ＋ / − in the status bar (deleting asks first). Views and `WITHOUT ROWID` tables are read-only.
- **Create and edit tables** with the ＋ / pencil / trash buttons under the list, or by right-clicking a table. Set each column's name, type, primary key, not null, unique and default in a grid; add, remove and reorder columns and rename the table, with the SQL to run shown live below, along with warnings such as which columns' data would be deleted. Renaming the table or adding columns at the end uses ALTER TABLE; other changes rebuild the table (new table, copy rows, swap names) in a transaction, which works on old SQLite too and undoes everything if a step fails. Foreign keys, CHECK constraints and triggers aren't kept through a rebuild, and you're told beforehand.
- **Indexes** in the same window, below the columns: add, change and remove CREATE INDEX indexes, each with a name, INDEX or UNIQUE, and columns, typed (with DESC or a collation, as in `created DESC, title COLLATE NOCASE`) or ticked from a menu. They follow a column that’s renamed and lose one that’s deleted; a rebuild makes them again on the new table. Partial indexes (with WHERE) and indexes on expressions are left as they are.
- **Create and edit views**: choose New View… from the ＋ button, or right-click a view (or use the pencil) to edit it. Enter a name, optional column names and the SELECT, and click Preview (⌘↩) to see its first 50 rows. Saving runs the SELECT first and refuses with the error if it fails (a missing table or column, say). SQLite has no ALTER VIEW, so an edit drops the view and creates it again in a transaction; triggers on the view are deleted, and you're told beforehand.
- **Structure**: the table's facts (rows, total, data and index size, unused space, next rowid or AUTOINCREMENT value, WITHOUT ROWID / STRICT), columns (type, not null, default, primary key), indexes and the syntax-colored CREATE statement. The gear button at its top right has the table's own actions: VACUUM, ANALYZE, export the table's structure as Markdown, print it, reset AUTOINCREMENT to one past the largest rowid, or set it to a value of your own.
- **Run SQL** in a syntax-colored editor with ⌘↩ or the ▶︎ at the right (blue while running, dark when the SQL has changed, off once it has run); with text selected, only the selection runs, and several statements can run at once. Shows the results, rows changed, time taken or the error. [SQLite_SQL_ref.md](SQLite_SQL_ref.md) (in Chinese) is a guide to SQLite’s SQL with runnable examples.
- **Stays responsive with large data**: reading rows, running SQL, exporting, importing, VACUUM, ANALYZE and the structure documents run in the background. After a moment the window shows what's happening (“Loading data…”, “Running the SQL…”), how many rows have arrived (for a file on this Mac) and for how long; **Cancel** (or Esc) stops the statement (`sqlite3_interrupt` on this Mac; over SSH, the remote sqlite3). Paging and sorting don't count the rows again, and the Structure tab is read only when you open it. Commands over SSH may now run for up to 10 minutes (it was 30 seconds), since they can be cancelled.
- **Structure document (Markdown)**: the document button in the toolbar, or ⇧⌘D, writes the structure of every table and view as one Markdown document: columns (type, not null, unique, default, primary key), foreign keys, indexes, triggers, row counts and CREATE statements, with tables lined up so the plain text reads well too. It opens in its own window rendered as Markdown (as 隨手記 previews it); switch to Markdown to see and edit the source, then Save As… (⌘S), Print… (⌘P; laid out again for the paper, always in light colors, and the print dialog can save a PDF) or Open in Default App; Regenerate makes it again from the database as it is now.
- **Database info** (⌘I or the ⓘ toolbar button): the file's name, folder (and server), size, when it was created and last changed, whether it's read-only, the unused space a VACUUM would give back, pages, journal mode, text encoding and SQLite version. Set **auto_vacuum** (NONE, FULL or INCREMENTAL; a VACUUM runs with the change so it takes effect), or **compact the database** with VACUUM, which shows the size before and after.
- **Import CSV** (⇧⌘I, the toolbar, or right-click a table) into the selected table. The separator (comma, tab or semicolon) and the text encoding (UTF-8, UTF-16, Big5, GB18030) are worked out from the file; quoted fields may hold commas, quotes and line breaks. Choose which CSV field fills each column (matched by name when the first line names the fields), whether empty fields are NULL, and whether to add to the table's rows or replace them, with the file's first lines shown. It all goes in one transaction: on an error nothing is imported. Works on databases on servers too.
- **Export CSV**: the query's results on the SQL tab, the whole table otherwise. UTF-8 with a BOM, so Excel reads Chinese correctly.
- **Copy** selected rows with ⌘C as tab-separated text, ready to paste into a spreadsheet.
- **Pinning**: the pin turns the window into a floating one you can drag anywhere (by its top edge or any empty space) and resize; it stays up while you use other apps and comes back where you left it. Unpin and it returns under the menu bar icon at the size it had before.
- **Show in the Dock, the menu bar, or both** (at least one stays on). With no menu bar icon, the window stays pinned and opens from the Dock.
- **Traditional Chinese / Simplified Chinese / English UI**, light or dark theme, and an option to open at login.

| Shortcut | Action |
|---|---|
| ⌘O / ⌘N | Open / New database |
| ⇧⌘O | Open a database on a server |
| ⌘D | Add this database to favorites |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌥⌘W | Close the tab |
| ⌘R | Refresh |
| ⌥⌘N / ⌥⇧⌘N | New table / New view |
| ⌥⌘E | Edit the selected table or view |
| ⇧⌘D | Structure document (Markdown) |
| ⌘1 / ⌘2 / ⌘3 | Data / Structure / SQL tab |
| ⌥⌘F | Filter rows |
| ⌥⌘K | Choose the columns to show |
| ⌘↩ | Run SQL |
| ⌘I | Database info |
| ⇧⌘I | Import CSV into the selected table |
| ⇧⌘E | Export CSV |
| ⌘C | Copy the selected rows |
| Esc | Hide the window |

## Install

Requires macOS 13 or later, on Intel or Apple silicon.

### Download

Paste this into Terminal to download the latest version, install it in Applications and open it:

```sh
curl -L https://github.com/janfon-source/MenuSQLite/releases/latest/download/MenuSQLite.zip -o /tmp/MenuSQLite.zip && ditto -x -k /tmp/MenuSQLite.zip /Applications && open /Applications/隨手SQLite.app
```

Or download the zip from [Releases](https://github.com/janfon-source/MenuSQLite/releases/latest), unzip it and move 隨手SQLite to Applications. The app isn't notarized, so a browser download is blocked the first time: try to open it, click Done at the warning, then click Open Anyway in System Settings → Privacy & Security. The Terminal command above avoids this.

### Build from source

Requires Xcode or the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/janfon-source/MenuSQLite.git
cd MenuSQLite
./build.sh install   # builds and installs /Applications/隨手SQLite.app
```

Run `./build.sh` alone to build into `build/隨手SQLite.app` without installing.

## Requirements for databases on servers

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

---

## 中文說明

點一下選單列圖示就能查資料、改資料、跑 SQL，按 Esc 就收起來。

### 功能

- **開啟與建立**：開啟任何 SQLite 資料庫（不限副檔名，依檔案內容判斷），或新增一個空的資料庫。記住最近開過的資料庫，下次啟動自動開回上次那個。
- **與執行中的程式共用**：資料庫正被其他程式使用時（例如 Node.js 的 better-sqlite3），遇到寫入鎖定會最多等 5 秒，而不是立刻顯示「database is locked」。WAL 模式的資料庫也能正常讀寫。
- **伺服器上的資料庫（SSH）**：輸入主機（`user@host` 或 `~/.ssh/config` 裡的 Host）、資料庫路徑，必要時加上連接埠和私鑰，就能操作伺服器上的 SQLite 檔案。透過 SSH 在伺服器上執行 `sqlite3`，直接讀寫那個檔案，不會下載或上傳整個資料庫；共用同一條 SSH 連線，第一次之後的操作都很快。用 SSH 金鑰或 ssh-agent 登入（不會詢問密碼），伺服器需要裝有 `sqlite3`。檔案沒有寫入權限時自動以唯讀開啟。主機欄位的下拉選單列出 `~/.ssh/config` 裡的 Host，選了就自動填入連接埠、私鑰和上次在那台主機用過的資料庫路徑。
- **同時開啟多個資料庫，以標籤頁切換**：每個開啟的資料庫（從資料夾按鈕、常用資料庫、最近開啟或 Finder）都在工具列下方有自己的標籤頁，名稱是常用資料庫裡設定的名稱，不是常用資料庫就顯示檔名（滑鼠移上去可看位置）。點標籤切換（⌃Tab／⌃⇧Tab 切到下一個／上一個），左右拖曳標籤可以調整前後順序；每個標籤都保留自己的資料表、頁數、排序、篩選、SQL 和查詢結果。同一個資料庫可以在多個標籤頁開啟，第二個起標上 (2)、(3)…。按 × 或 ⌥⌘W 關閉標籤頁，按 ＋ 在新標籤頁開啟資料庫。
- **常用資料庫**（工具列的星號按鈕）：點一下就開啟常用的資料庫。「將目前的資料庫加入常用資料庫…」（⌘D）把目前的資料庫（本機檔案或伺服器上的）存成自訂名稱；「管理常用資料庫…」可以新增、複製、編輯、刪除，拖曳調整順序，雙擊或按「開啟」就能打開。
- **瀏覽資料**：左側列出資料表和視圖，右側表格顯示資料，點欄位標題排序，每頁 200 列可翻頁。NULL 和 BLOB 以淡色顯示。
- **篩選資料列**：按資料上方的篩選按鈕（⌥⌘F），選欄位、方式（`=`、`!=`、`>`、`<`、`>=`、`<=`、`LIKE`、`NOT LIKE`、`IS NULL`、`IS NOT NULL`、`IS EMPTY`、`IS NOT EMPTY`）和值，可用 AND／OR 再加條件。資料列數和翻頁都依篩選結果；SQL 分頁會自動寫好對應的 SELECT（含排序），自己改過之後就不再覆寫。
- **選擇要顯示的欄位**（篩選按鈕旁的清單按鈕，或 ⌥⌘K）：下拉選單列出每個欄位，取消勾選就隱藏，選單不會關閉，可以連續調整。預設全部顯示，「全部顯示」可一次恢復。每個資料表的選擇在 App 執行期間都會記住；狀態列會顯示隱藏了幾欄，⌘C 只拷貝顯示中的欄位，SQL 分頁的 SELECT 也只列出這些欄位。
- **重新載入資料**（資料下方的箭頭按鈕）：重新讀取目前這一頁，篩選、排序和頁數不變，用來看其他程式或 SQL 分頁改過的資料。
- **匯出資料畫面的內容**（資料下方的匯出按鈕）：依目前的篩選條件、排序和顯示中的欄位，把全部符合的資料列匯出成 CSV，不受每頁 200 列的限制。SQL 分頁下方的同一個按鈕匯出查詢結果：從資料分頁自動帶入的 SELECT 會拿掉 LIMIT 100 重新查詢；自己寫的 SQL 則匯出畫面上的結果，不會重新執行（以免再次改到資料）。
- **直接編輯**：按兩下儲存格修改，右鍵可設為 NULL；狀態列的 ＋／− 按鈕新增或刪除資料列（刪除前會確認）。視圖和 `WITHOUT ROWID` 資料表為唯讀。
- **新增與編輯資料表**：左側清單下方的 ＋／鉛筆／垃圾桶按鈕，或在資料表上按右鍵。在表格裡設定每個欄位的名稱、類型、主鍵、非空、唯一和預設值，可新增、刪除、上下移動欄位、重新命名資料表；下方即時顯示將執行的 SQL，以及會刪除哪些欄位資料等提醒。只改名稱或在最後新增欄位時直接 ALTER TABLE；其他變更以「建新表、搬資料、換名字」的方式在交易中完成（舊版 SQLite 也適用），失敗時整個還原。外鍵、CHECK 限制和觸發程序在重建時不會保留，會事先提醒。
- **索引**：同一個視窗的欄位下方，可以新增、修改、刪除用 CREATE INDEX 建立的索引，設定名稱、INDEX 或 UNIQUE 和欄位；欄位可以直接輸入（可加 DESC 或定序，例如 `created DESC, title COLLATE NOCASE`），也可以從選單勾選。欄位改名時索引跟著改，刪除欄位時也會從索引移除；重建資料表時會在新表上重建索引。部分索引（帶 WHERE）和運算式索引維持原樣。
- **新增與編輯視圖**：＋ 按鈕選「新增視圖…」，或在視圖上按右鍵／鉛筆按鈕編輯。輸入名稱、選填的欄位名稱和 SELECT 語句，按「預覽結果」（⌘↩）先看前 50 列。儲存前會先執行一次 SELECT，有錯（例如資料表或欄位不存在）就顯示錯誤、不會存檔。SQLite 沒有 ALTER VIEW，編輯時在交易中刪除舊視圖再建立新的；視圖上的觸發程序會因此刪除，會事先提醒。
- **結構**：資料表資訊（資料列數、總大小、資料和索引大小、未使用的空間、下一個 rowid 或自動遞增值、WITHOUT ROWID／STRICT）、欄位（類型、非空、預設值、主鍵）、索引，以及有語法上色的 CREATE 語句。右上角的齒輪按鈕是這個資料表的功能：壓縮資料庫（VACUUM）、分析（ANALYZE）、把結構匯出成 Markdown、列印、把自動遞增值重設為目前最大值加 1，或設成自己指定的值。
- **執行 SQL**：語法上色的編輯器，⌘↩ 或右側的 ▶︎ 執行（執行中藍色、SQL 有更動時深色、執行完停用）；有選取文字時只執行選取的部分，可一次執行多個語句。顯示結果、影響列數、耗時或錯誤訊息。SQLite 的 SQL 語法和範例整理在 [SQLite_SQL_ref.md](SQLite_SQL_ref.md)。
- **大量資料時不卡住**：讀取資料、執行 SQL、匯出、匯入、VACUUM、ANALYZE 和產生結構文件都在背景進行。稍等一下視窗就會顯示正在做什麼（「正在讀取資料…」「正在執行 SQL…」）、已讀取多少列（本機的檔案）和經過幾秒；按**取消**（或 Esc）會停止這個語句（本機用 `sqlite3_interrupt`，透過 SSH 時停止遠端的 sqlite3）。換頁和排序不再重新計算總列數，結構分頁也改成打開時才讀取。因為可以取消，透過 SSH 的指令最長可以執行 10 分鐘（原本 30 秒）。
- **結構文件（Markdown）**：工具列的文件按鈕或 ⇧⌘D，把目前資料庫所有資料表和視圖的結構整理成一份 Markdown：欄位（類型、非空、唯一、預設值、主鍵）、外鍵、索引、觸發程序、資料列數和建立語句，表格已對齊，純文字也好讀。文件在獨立視窗以排版後的 Markdown 顯示（與隨手記的預覽相同）；切到「Markdown」可看原始碼並修改，再「另存新檔…」（⌘S）、「列印…」（⌘P，依紙張寬度重新排版，一律以淺色列印，也可在列印對話框存成 PDF）或「用預設 App 開啟」（例如隨手記）；「重新產生」依資料庫最新狀態重做。
- **資料庫資訊**（⌘I 或工具列的 ⓘ 按鈕）：檔名、所在資料夾（伺服器上的資料庫另外列出主機）、大小、建立日期和最後更動日期、是否唯讀，以及 VACUUM 可以回收的未使用空間、頁數、日誌模式、文字編碼和 SQLite 版本。可以設定 **auto_vacuum**（NONE、FULL、INCREMENTAL；變更時會一併執行 VACUUM 讓設定生效），或執行 VACUUM **壓縮資料庫**，並顯示壓縮前後的大小。
- **匯入 CSV**（⇧⌘I、工具列按鈕，或在資料表上按右鍵）到選取的資料表。自動判斷分隔符號（逗號、Tab、分號）和文字編碼（UTF-8、UTF-16、Big5、GB18030），引號裡的逗號、引號和換行都能正確讀取。可以指定每個欄位要填入哪一欄 CSV（第一列是欄位名稱時會依名稱自動配對）、空白欄位是否存成 NULL，以及加在現有資料後面或先清空再匯入，並預覽檔案的前幾列。整批在一個交易中完成，出錯就完全不匯入。伺服器上的資料庫也能用。
- **匯出 CSV**：SQL 分頁匯出查詢結果，其他分頁匯出整個資料表。UTF-8 含 BOM，Excel 開啟中文不會亂碼。
- **拷貝**：選取資料列按 ⌘C，以 Tab 分隔拷貝，可直接貼到試算表。
- **釘選視窗**：按圖釘後，視窗變成可自由拖曳（拖上緣或空白處）、可調整大小的浮動視窗，切換到其他 App 也不會收起，下次顯示仍在原處；再按一次解除釘選，視窗回到選單列圖示下方、釘選前的大小。
- **顯示在 Dock、選單列或兩者**（至少要顯示一個）。不顯示在選單列時，視窗固定為釘選，從 Dock 開啟。
- **繁體中文／简体中文／English 介面**、淺色／深色主題、登入時自動開啟。

| 快捷鍵 | 功能 |
|---|---|
| ⌘O / ⌘N | 開啟 / 新增資料庫 |
| ⇧⌘O | 連線到伺服器上的資料庫 |
| ⌘D | 將目前的資料庫加入常用資料庫 |
| ⌃Tab / ⌃⇧Tab | 下一個 / 上一個標籤頁 |
| ⌥⌘W | 關閉標籤頁 |
| ⌘R | 重新整理 |
| ⌥⌘N / ⌥⇧⌘N | 新增資料表 / 新增視圖 |
| ⌥⌘E | 編輯選取的資料表或視圖 |
| ⇧⌘D | 結構文件（Markdown） |
| ⌘1 / ⌘2 / ⌘3 | 資料 / 結構 / SQL 分頁 |
| ⌥⌘F | 篩選資料列 |
| ⌥⌘K | 選擇要顯示的欄位 |
| ⌘↩ | 執行 SQL |
| ⌘I | 資料庫資訊 |
| ⇧⌘I | 匯入 CSV 到選取的資料表 |
| ⇧⌘E | 匯出 CSV |
| ⌘C | 拷貝選取的資料列 |
| Esc | 收起視窗 |

### 安裝

需要 macOS 13 以上，Intel 和 Apple 晶片的 Mac 都可以。

#### 直接下載

在「終端機」貼上這一行，會下載最新版、安裝到「應用程式」並打開：

```sh
curl -L https://github.com/janfon-source/MenuSQLite/releases/latest/download/MenuSQLite.zip -o /tmp/MenuSQLite.zip && ditto -x -k /tmp/MenuSQLite.zip /Applications && open /Applications/隨手SQLite.app
```

也可以到 [Releases](https://github.com/janfon-source/MenuSQLite/releases/latest) 下載壓縮檔，解壓縮後把「隨手SQLite」拖到「應用程式」。隨手SQLite 沒有經過 Apple 公證，用瀏覽器下載的版本第一次打開會被擋下：先打開一次，出現警告後按「完成」，再到「系統設定」→「隱私權與安全性」，在下方按「強制打開」。用上面的終端機指令安裝則不會被擋。

#### 從原始碼編譯

需要 Xcode 或 Command Line Tools（`xcode-select --install`）。

```sh
git clone https://github.com/janfon-source/MenuSQLite.git
cd MenuSQLite
./build.sh install   # 編譯並安裝到 /Applications/隨手SQLite.app
```

只想編譯不安裝就執行 `./build.sh`，結果在 `build/隨手SQLite.app`。

### 連線到伺服器的需求

透過 SSH 開啟伺服器上的資料庫時，需要：

- 用 **SSH 金鑰或 ssh-agent** 登入伺服器（隨手SQLite 不會詢問密碼）。
- 伺服器上裝有 **`sqlite3` 指令**。

隨手SQLite 連線時會自動檢查，沒有 `sqlite3` 會直接提示。也可以在終端機手動確認：

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

舊版的 `sqlite3`（例如 CentOS 7 內建的 3.7.17）也可以使用：隨手SQLite 會自動偵測，改用 CSV 格式取得資料。這時以文字存放的數字會顯示成數字（只影響對齊），BLOB 欄位無法正確顯示。

**權限**：隨手SQLite 用 SSH 登入的帳號讀寫檔案。要修改資料，這個帳號需要檔案和所在資料夾的寫入權限（SQLite 修改時會在同一個資料夾建立暫存檔），否則會以唯讀開啟。找不到檔案或沒有權限進入資料夾時，錯誤訊息會註明登入的帳號和主機，以及同一個資料夾裡的資料庫檔案。

## License

[MIT](LICENSE) © 2026 Jeff Lee
