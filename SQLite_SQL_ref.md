# SQLite SQL 語法說明

這份文件整理 SQLite 常用的 SQL 語法：建立資料表、查詢與修改資料、索引、視圖、觸發程序、交易、常用函式和 PRAGMA，也列出和其他資料庫不同、容易踩到的地方。

所有範例都用同一組資料（「部門」和「員工」兩個資料表），在空的資料庫裡從上往下執行就能得到文中的結果。在隨手SQLite 裡新增一個資料庫，切到 SQL 分頁（⌘3），貼上範例後按 ⌘↩ 執行；只想執行其中一句，先選取那一句再按 ⌘↩。

標示「3.xx 起」的語法需要該版以上的 SQLite。可以用 `SELECT sqlite_version();` 查目前的版本。macOS 內建的版本很新；伺服器上的 sqlite3 可能很舊，文末的[版本對照](#版本對照)列出各功能從哪一版開始支援。

[TOC]

## 基本規則

### 大小寫、註解與分號

```sql
-- 兩個減號到行尾是註解
/* 也可以用這種
   跨行的註解 */
select 1 + 1;          -- 關鍵字不分大小寫
SELECT 'A' = 'a';      -- 字串比較預設分大小寫：結果 0
```

每句 SQL 以分號結尾。一次可以執行好幾句，SQLite 依序執行，遇到錯誤就停下。

### 字串、名稱與常值

| 寫法 | 意思 | 範例 |
|---|---|---|
| `'文字'` | 字串，裡面的單引號寫兩次 | `'It''s'` |
| `"名稱"` | 資料表或欄位名稱，可含空白、中文或保留字 | `"order"`、`"月 營收"` |
| `[名稱]`、`` `名稱` `` | 同上，相容 SQL Server 和 MySQL 的寫法 | `[order]` |
| `123`、`3.14`、`1e3`、`0x1F` | 整數、實數、科學記號、十六進位 | |
| `X'CAFE'` | BLOB（二進位資料），兩位十六進位一個位元組 | |
| `NULL` | 沒有值 | |
| `TRUE`、`FALSE` | 就是 `1` 和 `0`（3.23 起） | |

> 字串一定用單引號。SQLite 為了相容舊程式，把找不到對應欄位的 `"雙引號"` 當成字串，打錯欄位名稱時不會報錯，而是默默比對一個字串，結果就錯了。

### 資料型別與型別親和性

SQLite 每個「值」有自己的型別，只有五種：

| 儲存型別 | 內容 |
|---|---|
| `NULL` | 沒有值 |
| `INTEGER` | 整數，最多 8 位元組 |
| `REAL` | 8 位元組浮點數 |
| `TEXT` | 文字（UTF-8 或 UTF-16） |
| `BLOB` | 原樣保存的二進位資料 |

欄位宣告的型別只是「親和性」（偏好），SQLite 會盡量把存入的值轉成那種型別，轉不了就照原樣存。依宣告的型別名稱判斷：

| 型別名稱含有 | 親和性 | 例如 |
|---|---|---|
| `INT` | INTEGER | `INT`、`INTEGER`、`BIGINT` |
| `CHAR`、`CLOB`、`TEXT` | TEXT | `VARCHAR(50)`、`TEXT` |
| `BLOB`，或沒寫型別 | BLOB | `BLOB` |
| `REAL`、`FLOA`、`DOUB` | REAL | `REAL`、`DOUBLE` |
| 其他 | NUMERIC | `NUMERIC`、`DECIMAL(10,2)`、`BOOLEAN`、`DATE` |

```sql
CREATE TABLE 型別示範 (i INTEGER, t TEXT, n NUMERIC);
INSERT INTO 型別示範 VALUES ('42', 42, '3.0');
INSERT INTO 型別示範 VALUES ('abc', NULL, 'xyz');
SELECT i, typeof(i), t, typeof(t), n, typeof(n) FROM 型別示範;
-- 42  integer | 42  text | 3    integer
-- abc text    | NULL null | xyz text
```

`VARCHAR(50)` 的長度不會被檢查。日期時間、布林值沒有專屬型別，通常存成文字（`'2026-10-22 13:45:00'`）、整數（Unix 時間、0/1）或實數（儒略日）。要嚴格檢查型別，用 [STRICT 資料表](#strict-資料表)。

## 建立資料表

### CREATE TABLE

```sql
CREATE TABLE 部門 (
    id    INTEGER PRIMARY KEY,
    名稱  TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS 員工 (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    姓名    TEXT NOT NULL,
    部門_id INTEGER REFERENCES 部門(id) ON DELETE SET NULL,
    薪資    REAL CHECK (薪資 >= 0),
    到職日  TEXT DEFAULT (date('now')),
    email   TEXT UNIQUE COLLATE NOCASE
);
```

`IF NOT EXISTS`：資料表已經存在時不做任何事，也不報錯。

欄位可以加的限制：

| 限制 | 意思 |
|---|---|
| `PRIMARY KEY` | 主鍵。多欄主鍵寫在最後：`PRIMARY KEY (a, b)` |
| `NOT NULL` | 不能是 NULL |
| `UNIQUE` | 不能重複（NULL 不算重複，可以有好幾個） |
| `DEFAULT 值` | 沒給值時的預設值；運算式要加括號，如 `DEFAULT (date('now'))` |
| `CHECK (條件)` | 存入的值必須讓條件成立 |
| `REFERENCES 表(欄)` | 外鍵，見[外鍵](#外鍵) |
| `COLLATE NOCASE` | 比較和排序時不分大小寫（只限英文字母） |
| `GENERATED ALWAYS AS (運算式)` | 計算欄位（3.31 起），見下方 |

### rowid 與 INTEGER PRIMARY KEY

每個資料表（`WITHOUT ROWID` 的除外）都有一個隱藏的整數欄位 `rowid`，是資料列真正的鍵值。宣告成 **`INTEGER PRIMARY KEY`** 的欄位就是 rowid 的別名：新增時不給值，就自動填入「目前最大值 + 1」。

```sql
INSERT INTO 部門 (名稱) VALUES ('研發部'), ('業務部'), ('行政部');
SELECT rowid, id, 名稱 FROM 部門;
-- 1 1 研發部
-- 2 2 業務部
-- 3 3 行政部
```

加上 `AUTOINCREMENT` 保證刪掉的編號不會再被用到（否則刪掉最後一列後，下一個編號可能重複），代價是稍慢。一般用 `INTEGER PRIMARY KEY` 就夠了。

> 只有寫成 `INTEGER PRIMARY KEY` 才是 rowid 的別名；寫成 `INT PRIMARY KEY` 或 `BIGINT PRIMARY KEY` 都只是普通的主鍵，不會自動編號。

### 計算欄位

```sql
CREATE TABLE 訂單 (
    數量  INTEGER,
    單價  REAL,
    小計  REAL GENERATED ALWAYS AS (數量 * 單價) VIRTUAL,
    含稅  REAL GENERATED ALWAYS AS (round(數量 * 單價 * 1.05)) STORED
);
INSERT INTO 訂單 (數量, 單價) VALUES (3, 120);
SELECT * FROM 訂單;   -- 3  120.0  360.0  378.0
```

`VIRTUAL` 每次讀取時計算，不佔空間；`STORED` 寫入時算好存起來。計算欄位不能直接寫入。

### STRICT 資料表

3.37 起，在最後加 `STRICT`，型別只能是 `INT`、`INTEGER`、`REAL`、`TEXT`、`BLOB`、`ANY`，存入不符合的值會報錯。

```sql
CREATE TABLE 嚴格 (id INTEGER PRIMARY KEY, 數量 INTEGER) STRICT;
INSERT INTO 嚴格 (數量) VALUES ('12');    -- 可以：'12' 能無損轉成整數
-- INSERT INTO 嚴格 (數量) VALUES ('abc'); -- 錯誤：cannot store TEXT value in INTEGER column
```

### WITHOUT ROWID

主鍵是文字或多個欄位、資料列又小的時候，`WITHOUT ROWID` 直接用主鍵組織資料，省空間也較快。必須有 `PRIMARY KEY`。

```sql
CREATE TABLE 設定 (
    鍵 TEXT PRIMARY KEY,
    值 TEXT
) WITHOUT ROWID;
```

### 從查詢結果建立

```sql
CREATE TABLE 部門備份 AS SELECT * FROM 部門;
```

只複製欄位名稱和資料，不會複製主鍵、限制和索引。

## 修改與刪除資料表

### ALTER TABLE

SQLite 的 ALTER TABLE 只能做這幾件事：

```sql
ALTER TABLE 部門備份 RENAME TO 舊部門;                -- 改資料表名稱
ALTER TABLE 舊部門 ADD COLUMN 電話 TEXT DEFAULT '';    -- 新增欄位（加在最後）
ALTER TABLE 舊部門 RENAME COLUMN 電話 TO 分機;          -- 改欄位名稱（3.25 起）
ALTER TABLE 舊部門 DROP COLUMN 分機;                   -- 刪除欄位（3.35 起）
```

`ADD COLUMN` 不能加 `PRIMARY KEY` 或 `UNIQUE` 欄位；加 `NOT NULL` 時一定要有非 NULL 的預設值。`DROP COLUMN` 不能刪主鍵、有 UNIQUE 限制、被索引或外鍵用到的欄位。

其他變更（改型別、加限制、調整欄位順序）要「重建」資料表：建新表、搬資料、刪舊表、改名。隨手SQLite 的「編輯資料表」會自動產生這段 SQL：

```sql
PRAGMA foreign_keys = OFF;
BEGIN;
CREATE TABLE 舊部門_new (id INTEGER PRIMARY KEY, 名稱 TEXT NOT NULL);
INSERT INTO 舊部門_new (id, 名稱) SELECT id, 名稱 FROM 舊部門;
DROP TABLE 舊部門;
ALTER TABLE 舊部門_new RENAME TO 舊部門;
COMMIT;
PRAGMA foreign_keys = ON;
```

### DROP TABLE

```sql
DROP TABLE IF EXISTS 舊部門;
```

資料表、它的索引和觸發程序一起刪除，無法復原。

## 新增資料

### INSERT

```sql
INSERT INTO 員工 (姓名, 部門_id, 薪資, 到職日, email)
VALUES ('王小明', 1, 68000, '2021-03-15', 'ming@example.com');

-- 一次新增多列
INSERT INTO 員工 (姓名, 部門_id, 薪資, 到職日, email) VALUES
    ('李美華', 1, 75000, '2019-07-01', 'mei@example.com'),
    ('陳大同', 2, 52000, '2023-01-09', 'tong@example.com'),
    ('林佳穎', 2, 58000, '2022-05-20', NULL),
    ('張志豪', NULL, 45000, '2024-02-01', 'hao@example.com');

-- 全部用預設值
INSERT INTO 型別示範 DEFAULT VALUES;

-- 從查詢結果新增
CREATE TABLE 高薪名單 (姓名 TEXT, 薪資 REAL);
INSERT INTO 高薪名單 SELECT 姓名, 薪資 FROM 員工 WHERE 薪資 >= 60000;
```

沒列出的欄位會填入預設值，沒有預設值就是 NULL。

### 衝突時怎麼辦：INSERT OR …

違反 `UNIQUE`、`NOT NULL`、`PRIMARY KEY` 等限制時的處理方式：

| 寫法 | 遇到衝突 |
|---|---|
| `INSERT`（即 `OR ABORT`） | 報錯，取消這一句的變更 |
| `INSERT OR IGNORE` | 跳過這一列，不報錯 |
| `INSERT OR REPLACE`（簡寫 `REPLACE`） | 刪掉衝突的舊列，再新增 |
| `INSERT OR FAIL` | 報錯，但保留這一句已經完成的變更 |
| `INSERT OR ROLLBACK` | 報錯，並還原整個交易 |

```sql
INSERT OR IGNORE INTO 部門 (id, 名稱) VALUES (1, '研發部');   -- id 1 已存在，略過
```

> `OR REPLACE` 是「刪除再新增」：沒給值的欄位會變回預設值，而且會觸發 ON DELETE 的外鍵動作。只想更新部分欄位，用下面的 UPSERT。

### UPSERT：存在就更新

3.24 起：

```sql
INSERT INTO 部門 (id, 名稱) VALUES (3, '管理部')
ON CONFLICT (id) DO UPDATE SET 名稱 = excluded.名稱;

INSERT INTO 部門 (名稱) VALUES ('研發部')
ON CONFLICT (名稱) DO NOTHING;
```

`excluded.欄位` 是這次想新增的值。`ON CONFLICT (欄位)` 指定的欄位要有 UNIQUE 限制或是主鍵。

### RETURNING

3.35 起，`INSERT`、`UPDATE`、`DELETE` 可以傳回受影響的資料列，例如取得自動編號：

```sql
INSERT INTO 部門 (名稱) VALUES ('財務部') RETURNING id, 名稱;
-- 4  財務部
```

也可以用 `SELECT last_insert_rowid();` 取得最近新增的 rowid。

## 查詢資料

### SELECT 基本形式

```sql
SELECT 姓名, 薪資, 薪資 * 12 AS 年薪
FROM 員工
WHERE 薪資 >= 50000 AND 部門_id IS NOT NULL
ORDER BY 薪資 DESC
LIMIT 3 OFFSET 0;
-- 李美華 75000.0 900000.0
-- 王小明 68000.0 816000.0
-- 林佳穎 58000.0 696000.0
```

各子句的執行順序是 `FROM` → `WHERE` → `GROUP BY` → `HAVING` → `SELECT` → `ORDER BY` → `LIMIT`。`AS` 取的別名可以用在 `ORDER BY`，但不能用在 `WHERE`。

| 子句 | 說明 |
|---|---|
| `SELECT DISTINCT 欄位` | 去掉重複的列 |
| `SELECT *` | 所有欄位；`員工.*` 指定某個表的所有欄位 |
| `ORDER BY 欄位 ASC/DESC` | 排序；`NULLS FIRST` / `NULLS LAST`（3.30 起）指定 NULL 排前或排後，預設 NULL 最小 |
| `LIMIT n OFFSET m` | 跳過 m 列後取 n 列；也可寫 `LIMIT m, n` |

### WHERE 條件

```sql
SELECT 姓名 FROM 員工 WHERE 薪資 BETWEEN 50000 AND 60000;     -- 包含兩端
SELECT 姓名 FROM 員工 WHERE 部門_id IN (1, 3);
SELECT 姓名 FROM 員工 WHERE 姓名 LIKE '王%';                   -- % 任意長度，_ 一個字
SELECT 姓名 FROM 員工 WHERE email GLOB '*@example.com';         -- 分大小寫，* 和 ?
SELECT 姓名 FROM 員工 WHERE email IS NULL;                      -- 不能寫 = NULL
SELECT 姓名 FROM 員工 WHERE 到職日 >= '2022-01-01';              -- 日期字串可以直接比
```

### 聚合與分組

```sql
SELECT 部門_id, count(*) AS 人數, avg(薪資) AS 平均薪資, max(薪資) AS 最高
FROM 員工
GROUP BY 部門_id
HAVING count(*) >= 2
ORDER BY 平均薪資 DESC;
-- 1 2 71500.0 75000.0
-- 2 2 55000.0 58000.0
```

`WHERE` 在分組前過濾資料列，`HAVING` 在分組後過濾群組。聚合函式見[聚合函式](#聚合函式)。

### 合併資料表：JOIN

```sql
-- 內部合併：兩邊都對得上的才列出
SELECT e.姓名, d.名稱 AS 部門
FROM 員工 AS e
JOIN 部門 AS d ON d.id = e.部門_id;

-- 左外部合併：員工全部列出，沒有部門的部門欄是 NULL
SELECT e.姓名, d.名稱 AS 部門
FROM 員工 e
LEFT JOIN 部門 d ON d.id = e.部門_id;

-- 找出沒有員工的部門
SELECT d.名稱
FROM 部門 d
LEFT JOIN 員工 e ON e.部門_id = d.id
WHERE e.id IS NULL;
```

| 寫法 | 結果 |
|---|---|
| `JOIN`、`INNER JOIN` | 兩邊都對得上的列 |
| `LEFT JOIN` | 左邊全部，右邊對不上補 NULL |
| `RIGHT JOIN` | 右邊全部（3.39 起） |
| `FULL JOIN` | 兩邊全部（3.39 起） |
| `CROSS JOIN`，或 `FROM a, b` | 所有組合 |
| `JOIN … USING (欄位)` | 兩邊同名欄位相等，等於 `ON a.欄位 = b.欄位` |
| `NATURAL JOIN` | 所有同名欄位都相等 |

### 子查詢

```sql
-- 當作一個值
SELECT 姓名, 薪資 FROM 員工 WHERE 薪資 > (SELECT avg(薪資) FROM 員工);

-- 當作清單
SELECT 名稱 FROM 部門 WHERE id IN (SELECT 部門_id FROM 員工 WHERE 薪資 > 60000);

-- EXISTS：有沒有符合的列
SELECT 名稱 FROM 部門 d WHERE EXISTS (SELECT 1 FROM 員工 e WHERE e.部門_id = d.id);

-- 當作資料表
SELECT 部門_id, 人數 FROM (SELECT 部門_id, count(*) AS 人數 FROM 員工 GROUP BY 部門_id) WHERE 人數 > 1;
```

### 合併查詢結果：UNION

```sql
SELECT 姓名 FROM 員工 WHERE 部門_id = 1
UNION ALL                 -- 保留重複；UNION 去掉重複
SELECT 姓名 FROM 員工 WHERE 薪資 < 50000;
```

`INTERSECT` 取兩邊都有的列，`EXCEPT` 取左邊有、右邊沒有的列。各段的欄位數要相同；`ORDER BY` 和 `LIMIT` 寫在最後，作用在整個結果。

### CASE

```sql
SELECT 姓名,
       CASE
           WHEN 薪資 >= 70000 THEN '高'
           WHEN 薪資 >= 50000 THEN '中'
           ELSE '一般'
       END AS 級距,
       CASE 部門_id WHEN 1 THEN '研發' WHEN 2 THEN '業務' ELSE '其他' END AS 部門
FROM 員工;
```

簡單的二選一可以用 `iif(條件, 成立時, 不成立時)`（3.32 起）。

### WITH：通用資料表運算式（CTE）

先替子查詢取名，再像資料表一樣使用，讓長查詢比較好讀：

```sql
WITH 部門統計 AS (
    SELECT 部門_id, avg(薪資) AS 平均
    FROM 員工
    GROUP BY 部門_id
)
SELECT e.姓名, e.薪資, round(s.平均) AS 部門平均
FROM 員工 e
JOIN 部門統計 s ON s.部門_id = e.部門_id
WHERE e.薪資 > s.平均;
-- 李美華 75000.0 71500.0
-- 林佳穎 58000.0 55000.0
```

加上 `RECURSIVE` 可以遞迴，例如產生數列或走訪樹狀資料：

```sql
WITH RECURSIVE 數列(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM 數列 WHERE n < 5
)
SELECT n FROM 數列;   -- 1 2 3 4 5
```

### 視窗函式

3.25 起，在不合併資料列的情況下，計算排名、累計、前後列比較：

```sql
SELECT 姓名, 部門_id, 薪資,
       rank()       OVER (ORDER BY 薪資 DESC)                       AS 全公司排名,
       row_number() OVER (PARTITION BY 部門_id ORDER BY 薪資 DESC)  AS 部門內排名,
       sum(薪資)    OVER (ORDER BY 到職日)                           AS 依到職日累計,
       薪資 - lag(薪資) OVER (ORDER BY 薪資)                         AS 與前一名差距
FROM 員工
ORDER BY 薪資 DESC;
```

| 函式 | 說明 |
|---|---|
| `row_number()` | 1, 2, 3…，同值也不同號 |
| `rank()` | 同值同名次，之後跳號（1, 1, 3） |
| `dense_rank()` | 同值同名次，不跳號（1, 1, 2） |
| `ntile(n)` | 平均分成 n 組 |
| `lag(欄, k)`、`lead(欄, k)` | 前 k 列、後 k 列的值 |
| `first_value(欄)`、`last_value(欄)` | 視窗內第一個、最後一個值 |
| `sum()`、`avg()`、`count()` 等 | 聚合函式加上 `OVER` 也能用 |

`PARTITION BY` 分組計算，`ORDER BY` 決定順序；可以再加範圍，如 `ROWS BETWEEN 2 PRECEDING AND CURRENT ROW`（目前列和前兩列）。

### VALUES 當作資料表

```sql
SELECT * FROM (VALUES (1, '一'), (2, '二')) AS t;
```

## 修改與刪除資料

### UPDATE

```sql
UPDATE 員工 SET 薪資 = 薪資 * 1.03 WHERE 部門_id = 2;

UPDATE 員工 SET 部門_id = 3, 薪資 = 47000 WHERE 姓名 = '張志豪';
```

3.33 起可以用 `FROM` 參照其他資料表：

```sql
CREATE TABLE 調薪 (姓名 TEXT, 加薪 REAL);
INSERT INTO 調薪 VALUES ('王小明', 2000), ('林佳穎', 1500);

UPDATE 員工 SET 薪資 = 薪資 + 調薪.加薪
FROM 調薪
WHERE 調薪.姓名 = 員工.姓名;
```

舊版的寫法是用子查詢，效果和上面相同（兩種擇一，不要都執行，否則會加薪兩次）：

```sql
-- UPDATE 員工 SET 薪資 = 薪資 + (SELECT 加薪 FROM 調薪 WHERE 調薪.姓名 = 員工.姓名)
-- WHERE 姓名 IN (SELECT 姓名 FROM 調薪);
```

### DELETE

```sql
DELETE FROM 高薪名單 WHERE 薪資 < 70000;
DELETE FROM 型別示範;          -- 刪除全部資料列，資料表還在
```

> 沒有 `WHERE` 的 `UPDATE` 和 `DELETE` 會作用在所有資料列。不確定時先用同樣的 `WHERE` 跑一次 `SELECT` 看看會影響哪些列，或在[交易](#交易)裡執行，確認後再 `COMMIT`。

## 運算子

| 運算子 | 說明 | 範例 → 結果 |
|---|---|---|
| `+ - * / %` | 四則運算、餘數 | `7 / 2` → `3`，`7 / 2.0` → `3.5`，`7 % 3` → `1` |
| `\|\|` | 字串串接 | `'王' \|\| '小明'` → `'王小明'` |
| `= == != <>` | 相等、不相等 | |
| `< <= > >=` | 大小比較 | |
| `IS`、`IS NOT` | 和 `=`、`!=` 一樣，但 NULL 也能比 | `NULL IS NULL` → `1` |
| `IS DISTINCT FROM` | 同 `IS NOT`（3.39 起） | |
| `AND OR NOT` | 邏輯運算 | |
| `BETWEEN a AND b` | 介於兩者之間（含兩端） | |
| `IN (…)` | 屬於清單或子查詢結果 | |
| `LIKE` | 樣式比對，英文字母不分大小寫 | `'Apple' LIKE 'a%'` → `1` |
| `GLOB` | 樣式比對（Unix 萬用字元），分大小寫 | `'Apple' GLOB 'A*'` → `1` |
| `->`、`->>` | 取 JSON 的值（3.38 起），見 [JSON](#json-函式) | |
| `& \| ~ << >>` | 位元運算 | `6 & 3` → `2` |

> 兩個整數相除的結果是整數（`7 / 2` 是 `3`）。要小數，把其中一個寫成實數：`7 / 2.0`，或 `CAST(7 AS REAL) / 2`。

### NULL 的規則

- 任何值和 NULL 做運算或比較，結果都是 NULL：`NULL + 1`、`NULL = NULL` 都是 NULL，所以 `WHERE 欄 = NULL` 永遠找不到資料，要用 `IS NULL`。
- 聚合函式（`count(欄)`、`sum`、`avg`…）會略過 NULL；`count(*)` 計算所有列。
- 用 `coalesce(欄, 替代值)` 或 `ifnull(欄, 替代值)` 把 NULL 換成別的值。

### CAST 型別轉換

```sql
SELECT CAST('123abc' AS INTEGER);   -- 123：從開頭取能轉的部分
SELECT CAST(3.99 AS INTEGER);       -- 3：直接捨去小數
SELECT CAST(42 AS TEXT) || '號';    -- 42號
```

### COLLATE：比較規則

```sql
SELECT 'abc' = 'ABC';                   -- 0
SELECT 'abc' = 'ABC' COLLATE NOCASE;    -- 1
SELECT 姓名 FROM 員工 ORDER BY email COLLATE NOCASE;
```

內建三種：`BINARY`（預設，逐位元組比較）、`NOCASE`（英文字母不分大小寫）、`RTRIM`（忽略結尾空白）。中文依 Unicode 編碼排序，不是依筆畫或注音。

## 常用函式

### 一般函式

| 函式 | 說明 | 範例 → 結果 |
|---|---|---|
| `coalesce(a, b, …)` | 第一個不是 NULL 的值 | `coalesce(NULL, '無')` → `'無'` |
| `ifnull(a, b)` | 同 `coalesce(a, b)` | |
| `nullif(a, b)` | a 等於 b 時傳回 NULL，否則傳回 a | `nullif(0, 0)` → NULL |
| `iif(條件, x, y)` | 條件成立傳回 x，否則 y（3.32 起） | `iif(1 > 2, '是', '否')` → `'否'` |
| `typeof(x)` | 值的型別 | `typeof(1.5)` → `'real'` |
| `max(a, b, …)`、`min(a, b, …)` | 多個值裡最大、最小的（不是聚合） | `max(3, 7, 5)` → `7` |
| `abs(x)` | 絕對值 | |
| `round(x, n)` | 四捨五入到小數 n 位 | `round(3.14159, 2)` → `3.14` |
| `random()` | 隨機整數 | `ORDER BY random()` 隨機排序 |
| `last_insert_rowid()` | 最近新增那一列的 rowid | |
| `changes()` | 上一句 INSERT/UPDATE/DELETE 影響的列數 | |
| `quote(x)` | 轉成 SQL 常值的寫法 | `quote('It''s')` → `'It''s'` |
| `hex(x)` | 轉成十六進位文字 | `hex('A')` → `'41'` |

### 文字函式

| 函式 | 說明 | 範例 → 結果 |
|---|---|---|
| `length(s)` | 字數（不是位元組數） | `length('隨手庫')` → `3` |
| `upper(s)`、`lower(s)` | 轉大寫、小寫（只限英文字母） | |
| `substr(s, 起, 長)` | 取一段，從 1 起算；起點為負數從尾端算 | `substr('2026-10-22', 6, 2)` → `'10'` |
| `trim(s)`、`ltrim(s)`、`rtrim(s)` | 去掉兩端（左、右）空白，或指定的字元 | `trim('--a--', '-')` → `'a'` |
| `replace(s, 舊, 新)` | 取代所有出現的地方 | `replace('a-b-c', '-', '/')` → `'a/b/c'` |
| `instr(s, 找)` | 第一次出現的位置，沒有則 0 | `instr('hello', 'l')` → `3` |
| `printf(格式, …)`、`format(…)` | 格式化（format 為 3.38 起的名稱） | `printf('%05d', 42)` → `'00042'` |
| `concat(a, b, …)` | 串接，略過 NULL（3.44 起） | |
| `concat_ws(分隔, a, b, …)` | 用分隔符號串接（3.44 起） | `concat_ws('-', 'a', 'b')` → `'a-b'` |
| `unicode(s)`、`char(n, …)` | 字元和 Unicode 碼互轉 | `unicode('中')` → `20013` |

`printf` 常用格式：`%d` 整數、`%f` 小數（`%.2f` 兩位）、`%s` 文字、`%,d` 千分位、`%5d` 補空白到 5 位、`%05d` 補零。

### 聚合函式

| 函式 | 說明 |
|---|---|
| `count(*)` | 列數 |
| `count(欄)` | 該欄不是 NULL 的列數；`count(DISTINCT 欄)` 不重複的值有幾種 |
| `sum(欄)` | 總和；全部是 NULL 時傳回 NULL，整數溢位會報錯 |
| `total(欄)` | 總和，一律傳回實數，全部是 NULL 時傳回 0.0 |
| `avg(欄)` | 平均，傳回實數 |
| `min(欄)`、`max(欄)` | 最小、最大值 |
| `group_concat(欄, 分隔)` | 把各列的值串成一個字串，預設以逗號分隔 |
| `string_agg(欄, 分隔)` | 同 `group_concat`（3.44 起） |

```sql
SELECT 部門_id, group_concat(姓名, '、') AS 成員
FROM 員工
GROUP BY 部門_id;

-- 只算符合條件的列（3.30 起）
SELECT count(*) FILTER (WHERE 薪資 >= 60000) AS 高薪人數,
       count(*) AS 總人數
FROM 員工;
```

3.44 起，聚合函式可以指定順序：`group_concat(姓名, '、' ORDER BY 薪資 DESC)`。

### 日期時間函式

SQLite 沒有日期型別，日期時間存成以下三種之一，函式都能讀：

- 文字：`'2026-10-22'`、`'2026-10-22 13:45:00'`（ISO 8601 格式，可以直接比較和排序）
- 整數：Unix 時間（1970-01-01 起算的秒數）
- 實數：儒略日

| 函式 | 結果 | 範例 → 結果 |
|---|---|---|
| `date(時間, 修飾…)` | `YYYY-MM-DD` | `date('2026-10-22', '+1 month')` → `'2026-11-22'` |
| `time(時間, 修飾…)` | `HH:MM:SS` | |
| `datetime(時間, 修飾…)` | `YYYY-MM-DD HH:MM:SS` | `datetime(1700000000, 'unixepoch')` → `'2023-11-14 22:13:20'` |
| `julianday(時間, 修飾…)` | 儒略日（實數），適合算天數差 | |
| `unixepoch(時間, 修飾…)` | Unix 時間（整數，3.38 起） | |
| `strftime(格式, 時間, 修飾…)` | 自訂格式 | `strftime('%Y年%m月', '2026-10-22')` → `'2026年10月'` |
| `timediff(a, b)` | 兩個時間的差（3.43 起） | |

`'now'` 代表現在，**是 UTC 時間**；要台灣時間加上 `'localtime'` 修飾：

```sql
SELECT datetime('now');                      -- UTC
SELECT datetime('now', 'localtime');         -- 本機時區（台灣為 UTC+8）
SELECT date('now', 'start of month');        -- 本月 1 日
SELECT date('now', 'start of month', '+1 month', '-1 day');   -- 本月最後一天
SELECT date('now', 'weekday 1');             -- 下一個星期一（今天是星期一就是今天）
SELECT julianday('2026-12-31') - julianday('2026-10-22');     -- 相差 70.0 天
SELECT 姓名, (julianday('now') - julianday(到職日)) / 365.25 AS 年資 FROM 員工;
SELECT strftime('%Y', 到職日) AS 年, count(*) FROM 員工 GROUP BY 年;
```

修飾：`'+N days'`、`'-N hours'`、`'+N months'`、`'+N years'`、`'start of day'`、`'start of month'`、`'start of year'`、`'weekday N'`（0 = 星期日）、`'localtime'`、`'utc'`、`'unixepoch'`。

`strftime` 格式：`%Y` 年、`%m` 月、`%d` 日、`%H` 時、`%M` 分、`%S` 秒、`%w` 星期（0–6，0 是星期日）、`%j` 一年中的第幾天、`%W` 一年中的第幾週、`%s` Unix 時間。

### 數學函式

3.35 起（需要編譯時啟用，macOS 內建版本有啟用）：`ceil`、`floor`、`trunc`、`sqrt`、`pow`、`exp`、`ln`、`log10`、`log2`、`log(底, x)`、`mod`、`pi()`、`sin`、`cos`、`tan` 等。

```sql
SELECT ceil(4.2), floor(4.8), sqrt(16), pow(2, 10), round(pi(), 4);
-- 5.0  4.0  4.0  1024.0  3.1416
```

### JSON 函式

文字欄位裡存 JSON，也能查詢、修改（3.38 起內建；更舊的版本要看編譯設定）：

```sql
CREATE TABLE 事件 (id INTEGER PRIMARY KEY, 資料 TEXT);
INSERT INTO 事件 (資料) VALUES
    ('{"類型": "登入", "使用者": {"名稱": "ming", "等級": 3}, "標籤": ["web", "mobile"]}'),
    ('{"類型": "登出", "使用者": {"名稱": "mei", "等級": 5}, "標籤": []}');

SELECT 資料 ->> '$.類型' AS 類型,
       資料 ->> '$.使用者.名稱' AS 使用者,
       json_array_length(資料, '$.標籤') AS 標籤數
FROM 事件
WHERE 資料 ->> '$.使用者.等級' >= 3;

-- 展開陣列，每個元素一列
SELECT e.id, t.value AS 標籤
FROM 事件 e, json_each(e.資料, '$.標籤') t;
```

| 函式 | 說明 |
|---|---|
| `json_extract(j, 路徑)` | 取值，路徑如 `'$.a.b[0]'` |
| `j -> 路徑`、`j ->> 路徑` | `->` 傳回 JSON 文字，`->>` 傳回 SQL 值（文字、數字） |
| `json_object(鍵, 值, …)`、`json_array(…)` | 組成 JSON |
| `json_set(j, 路徑, 值)`、`json_remove(j, 路徑)` | 修改，傳回新的 JSON |
| `json_array_length(j, 路徑)` | 陣列長度 |
| `json_each(j)`、`json_tree(j)` | 把 JSON 展開成資料表 |
| `json_group_array(欄)`、`json_group_object(鍵, 值)` | 聚合成 JSON 陣列、物件 |
| `json_valid(j)` | 是否為正確的 JSON |

## 索引

索引讓查詢、排序、合併更快，代價是佔空間、寫入稍慢。常用在 `WHERE`、`JOIN … ON`、`ORDER BY` 的欄位上。

```sql
CREATE INDEX idx_員工_部門 ON 員工 (部門_id);
CREATE UNIQUE INDEX idx_部門_名稱 ON 部門 (名稱);           -- 同時保證不重複
CREATE INDEX idx_員工_部門_薪資 ON 員工 (部門_id, 薪資 DESC);  -- 多欄索引
CREATE INDEX idx_員工_email ON 員工 (lower(email));         -- 運算式索引（3.9 起）
CREATE INDEX idx_在職 ON 員工 (姓名) WHERE 部門_id IS NOT NULL;  -- 部分索引（3.8 起）
DROP INDEX IF EXISTS idx_在職;
```

多欄索引從最左邊的欄位開始才用得上：`(部門_id, 薪資)` 可以加速 `WHERE 部門_id = 1` 和 `WHERE 部門_id = 1 AND 薪資 > 50000`，不能加速只有 `WHERE 薪資 > 50000` 的查詢。

用 `EXPLAIN QUERY PLAN` 看查詢有沒有用到索引：

```sql
EXPLAIN QUERY PLAN SELECT * FROM 員工 WHERE 部門_id = 1;
-- SEARCH 員工 USING INDEX idx_員工_部門_薪資 (部門_id=?)   ← 有用到索引
-- 如果是 SCAN 員工，表示逐列掃描整個資料表
```

`PRIMARY KEY` 和 `UNIQUE` 限制會自動建立索引（名稱以 `sqlite_autoindex_` 開頭）。資料變動很多之後，執行 `ANALYZE;` 或 `PRAGMA optimize;` 讓 SQLite 更新統計資料，選出更好的查詢方式。

## 視圖

視圖是存起來的查詢，用起來像資料表，但不存資料，每次讀取時重新查詢。

```sql
CREATE VIEW 員工明細 AS
SELECT e.id, e.姓名, d.名稱 AS 部門, e.薪資
FROM 員工 e
LEFT JOIN 部門 d ON d.id = e.部門_id;

SELECT * FROM 員工明細 WHERE 薪資 > 50000;

DROP VIEW IF EXISTS 員工明細;
```

- 可以指定欄位名稱：`CREATE VIEW v (名稱, 金額) AS SELECT …`。
- SQLite 沒有 `ALTER VIEW`，要修改就刪掉重建。隨手SQLite 的「編輯視圖」會在交易中自動做這件事。
- 視圖是唯讀的，不能直接 INSERT、UPDATE、DELETE；需要的話用 `INSTEAD OF` 觸發程序。
- 建立視圖時 SQLite 不檢查參照的資料表或欄位是否存在，要等讀取時才會出錯。隨手SQLite 會在儲存前先預覽一次查詢。
- `CREATE TEMP VIEW` 建立暫時的視圖，連線關閉就消失。

## 觸發程序

在資料表新增、修改、刪除資料列時，自動執行一段 SQL。

```sql
CREATE TABLE 薪資紀錄 (員工_id INTEGER, 舊薪資 REAL, 新薪資 REAL, 時間 TEXT);

CREATE TRIGGER 記錄調薪
AFTER UPDATE OF 薪資 ON 員工
WHEN NEW.薪資 <> OLD.薪資
BEGIN
    INSERT INTO 薪資紀錄 VALUES (NEW.id, OLD.薪資, NEW.薪資, datetime('now', 'localtime'));
END;

CREATE TRIGGER 禁止減薪
BEFORE UPDATE OF 薪資 ON 員工
WHEN NEW.薪資 < OLD.薪資
BEGIN
    SELECT RAISE(ABORT, '薪資不能調降');
END;

UPDATE 員工 SET 薪資 = 薪資 + 1000 WHERE id = 1;
SELECT * FROM 薪資紀錄;
```

| 寫法 | 說明 |
|---|---|
| `BEFORE` / `AFTER` | 在變更之前、之後執行 |
| `INSTEAD OF` | 取代原本的動作，只能用在視圖上，讓視圖可以寫入 |
| `INSERT` / `DELETE` / `UPDATE [OF 欄位]` | 觸發的動作；`UPDATE OF` 只在指定欄位被修改時觸發 |
| `NEW.欄位`、`OLD.欄位` | 變更後、變更前的值（INSERT 只有 NEW，DELETE 只有 OLD） |
| `WHEN 條件` | 條件成立才執行 |
| `RAISE(ABORT, '訊息')` | 中止並傳回錯誤訊息；也可用 `IGNORE`、`ROLLBACK`、`FAIL` |

刪除：`DROP TRIGGER IF EXISTS 記錄調薪;`

## 外鍵

外鍵確保「員工的部門_id」一定對得到「部門的 id」。**SQLite 預設不檢查外鍵**，每次連線都要先開啟：

```sql
PRAGMA foreign_keys = ON;

-- INSERT INTO 員工 (姓名, 部門_id) VALUES ('測試', 99);  -- 錯誤：FOREIGN KEY constraint failed
DELETE FROM 部門 WHERE id = 2;                        -- 員工的部門_id 依 ON DELETE SET NULL 變成 NULL
SELECT 姓名, 部門_id FROM 員工 WHERE 姓名 IN ('陳大同', '林佳穎');
```

被參照的欄位（`部門.id`）必須是主鍵或有 UNIQUE 限制。刪除或修改被參照的資料列時的動作：

| 寫法 | 動作 |
|---|---|
| `ON DELETE NO ACTION`（預設） / `RESTRICT` | 還有資料參照時不准刪 |
| `ON DELETE CASCADE` | 一起刪除參照它的資料列 |
| `ON DELETE SET NULL` | 參照它的欄位設為 NULL |
| `ON DELETE SET DEFAULT` | 參照它的欄位設為預設值 |
| `ON UPDATE …` | 同上，作用在修改被參照的值時 |

檢查既有資料有沒有對不上的：`PRAGMA foreign_key_check;`

## 交易

一組變更要嘛全部完成，要嘛全部不做：

```sql
BEGIN;
UPDATE 員工 SET 薪資 = 薪資 + 1000 WHERE 部門_id = 1;
INSERT INTO 部門 (名稱) VALUES ('客服部');
COMMIT;        -- 確定；改用 ROLLBACK 則全部取消
```

| 寫法 | 說明 |
|---|---|
| `BEGIN` / `BEGIN DEFERRED` | 開始交易，第一次讀寫時才鎖定 |
| `BEGIN IMMEDIATE` | 立刻取得寫入鎖，避免中途才發現別人在寫 |
| `BEGIN EXCLUSIVE` | 連讀取也擋住（WAL 模式下同 IMMEDIATE） |
| `COMMIT` / `END` | 確定變更 |
| `ROLLBACK` | 取消變更 |
| `SAVEPOINT 名稱` / `RELEASE 名稱` / `ROLLBACK TO 名稱` | 交易中的存檔點，可以只取消一部分 |

不在交易中時，每一句都自成一個交易。大量 INSERT 時包在一個交易裡，速度可以快上百倍。

## PRAGMA：資料庫設定與資訊

| PRAGMA | 用途 |
|---|---|
| `PRAGMA table_info(表)` | 欄位清單：名稱、型別、非空、預設值、主鍵 |
| `PRAGMA table_xinfo(表)` | 同上，含隱藏欄位和計算欄位 |
| `PRAGMA index_list(表)`、`PRAGMA index_info(索引)` | 資料表的索引、索引的欄位 |
| `PRAGMA foreign_key_list(表)` | 資料表的外鍵 |
| `PRAGMA foreign_keys = ON` | 開啟外鍵檢查（每次連線都要設） |
| `PRAGMA journal_mode = WAL` | 改用 WAL 模式：讀寫可以同時進行，適合網站和多個程式共用（設定一次會保存在檔案裡） |
| `PRAGMA busy_timeout = 5000` | 遇到鎖定時最多等幾毫秒，而不是立刻報錯 |
| `PRAGMA integrity_check` | 檢查資料庫檔案是否損壞，正常時傳回 `ok` |
| `PRAGMA user_version` | 一個自訂的整數，常用來記錄資料表結構的版本 |
| `PRAGMA page_count`、`PRAGMA page_size` | 兩者相乘就是檔案大小 |
| `PRAGMA optimize` | 更新查詢最佳化需要的統計資料，適合在關閉連線前執行 |

```sql
PRAGMA table_info(員工);
PRAGMA user_version = 2;
```

## 其他

### 資料庫結構

所有資料表、索引、視圖、觸發程序的定義都存在 `sqlite_schema`（舊名 `sqlite_master`，兩個名稱都能用）：

```sql
SELECT type, name, sql FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name;
```

隨手SQLite 的「結構文件」（⇧⌘D）會把這些整理成 Markdown。

### ATTACH：同時使用多個資料庫檔案

```sql
ATTACH DATABASE '/path/to/other.db' AS 另一個;
SELECT * FROM 另一個.某資料表;
INSERT INTO main.部門 SELECT * FROM 另一個.部門;   -- 在兩個檔案之間複製資料
DETACH DATABASE 另一個;
```

### VACUUM：整理資料庫檔案

刪除大量資料後檔案不會自動變小，`VACUUM` 重整檔案、釋放空間。3.27 起 `VACUUM INTO '備份.db'` 可以把整個資料庫複製成一個新檔案，適合做備份。

```sql
VACUUM;
```

### 全文檢索 FTS5

需要在大量文字裡搜尋關鍵字時，用 FTS5 虛擬資料表比 `LIKE '%字%'` 快得多：

```sql
CREATE VIRTUAL TABLE 文章 USING fts5(標題, 內容, tokenize = 'trigram');
INSERT INTO 文章 VALUES ('SQLite 入門', '輕量的嵌入式資料庫'), ('索引技巧', '讓查詢變得更快');
SELECT 標題 FROM 文章 WHERE 文章 MATCH '嵌入式';   -- SQLite 入門
SELECT 標題 FROM 文章 WHERE 文章 MATCH 'sqlite';   -- SQLite 入門（英文不分大小寫）
```

> FTS5 預設的切詞方式依空白和標點分詞，一整串中文會被當成一個詞，搜尋其中幾個字找不到。中文請用 `tokenize = 'trigram'`（3.34 起），搜尋的關鍵字至少要三個字；少於三個字改用 `LIKE '%字%'`，trigram 索引也能加速這種 `LIKE`。

## 和其他資料庫不同的地方

- **欄位型別不強制**：`INTEGER` 欄位可以存進文字，`VARCHAR(10)` 也不限長度。需要檢查就用 `STRICT` 資料表或 `CHECK` 限制。
- **沒有日期、布林型別**：日期存成 ISO 8601 文字最方便；布林存成 0/1。
- **外鍵預設關閉**：每次連線都要 `PRAGMA foreign_keys = ON`。
- **整數除法**：`5 / 2` 是 `2`。
- **`LIKE` 不分大小寫**（只限英文），`=` 和 `GLOB` 分大小寫。
- **雙引號是名稱**：字串用單引號，否則欄位名稱打錯時不會報錯。
- **`'now'` 是 UTC**：要本地時間加 `'localtime'`。
- **ALTER TABLE 能做的有限**：改型別、加限制要重建資料表。
- **沒有 `ALTER VIEW`**：刪掉重建。
- **沒有使用者和權限**：誰能讀寫檔案，誰就能讀寫資料庫。
- **同一時間只能有一個寫入者**：寫入時整個資料庫鎖定。用 WAL 模式讓讀取不受影響，並設定 `busy_timeout` 等待別人寫完。
- **AUTOINCREMENT 通常不需要**：`INTEGER PRIMARY KEY` 本身就會自動編號。
- **`UPDATE`／`DELETE` 不能加 `LIMIT`**（除非編譯時啟用），改用 `WHERE rowid IN (SELECT rowid FROM … LIMIT n)`。

## 版本對照

伺服器上的 SQLite 可能很舊（例如 CentOS 7 是 3.7.17）。在伺服器上執行 `sqlite3 --version` 查詢版本，再對照下表。

| 功能 | 最低版本 |
|---|---|
| 部分索引（`CREATE INDEX … WHERE`） | 3.8.0 |
| `WITHOUT ROWID` | 3.8.2 |
| `WITH` 通用資料表運算式、`printf()` | 3.8.3 |
| 運算式索引 | 3.9.0 |
| `TRUE`、`FALSE` | 3.23.0 |
| UPSERT（`ON CONFLICT … DO UPDATE`） | 3.24.0 |
| 視窗函式、`ALTER TABLE RENAME COLUMN` | 3.25.0 |
| `VACUUM INTO` | 3.27.0 |
| `NULLS FIRST` / `NULLS LAST`、聚合的 `FILTER` | 3.30.0 |
| 計算欄位（`GENERATED ALWAYS AS`） | 3.31.0 |
| `iif()` | 3.32.0 |
| `UPDATE … FROM`、`sqlite_schema` 名稱 | 3.33.0 |
| FTS5 的 `trigram` 切詞 | 3.34.0 |
| `RETURNING`、`ALTER TABLE DROP COLUMN`、數學函式 | 3.35.0 |
| `STRICT` 資料表 | 3.37.0 |
| `->` / `->>`、`unixepoch()`、`format()`、JSON 預設內建 | 3.38.0 |
| `RIGHT JOIN`、`FULL JOIN`、`IS DISTINCT FROM` | 3.39.0 |
| `timediff()` | 3.43.0 |
| `string_agg()`、`concat()`、`concat_ws()`、聚合內的 `ORDER BY` | 3.44.0 |

完整的官方文件：[sqlite.org/lang.html](https://www.sqlite.org/lang.html)
