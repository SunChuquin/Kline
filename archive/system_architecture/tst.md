``` mermaid
flowchart TB
    %% ============ 配色 ============
    style TOOL fill:#eceff1,stroke:#455a64,stroke-width:2px
    style MGR fill:#eef4ff,stroke:#4a6fa5,stroke-width:2px
    style QRY fill:#e3f2fd,stroke:#1565c0,stroke-width:2px
    style SEED fill:#f1f8e9,stroke:#33691e,stroke-width:2px
    style DOC fill:#f1f8e9,stroke:#33691e,stroke-width:2px

    subgraph TOOL["数据生成（仓库 src/）"]
        PARSER["tdx_parser.py · tdx_gui.py<br/>通达信数据 → SQLite"]
        PARSER -->|生成并入库| SEED[("tdx.db 种子库（随 App 打包）")]
    end

    APP["App 启动 · 首个页面引用 DatabaseManager.shared"] --> INIT["单例 init"]
    INIT --> QUEUE["dbQueue 串行队列<br/>（单一连接 · 串行化全部 SQL 操作）"]
    QUEUE --> LOAD["loadDatabase()"]

    subgraph MGR["数据库加载（DatabaseManager）"]
        CHECK{"Documents/tdx.db<br/>是否存在？"}
        CHECK -- "否（首次启动）" --> SEED
        SEED -->|"copyItem 复制"| DOC[("Documents/tdx.db<br/>可写副本")]
        CHECK -- "是" --> DOC
        DOC --> OPEN["sqlite3_open 打开可写库"]
        OPEN -- "失败" --> ERR["errorMessage + DebugLogger"]
        OPEN -- "成功" --> META["loadMetaList()<br/>SELECT id,file,code,name,type,first_date,last_date FROM meta"]
        META --> PUB["主线程更新 @Published<br/>isLoaded = true · metaList"]
    end
    LOAD --> CHECK

    subgraph QRY["查询路径（页面触发 · dbQueue 串行）"]
        FB["fetchBars(metaId, period)<br/>→ daily / weekly / monthly / quarterly / yearly"]
        FL["fetchPeriodLimited<br/>→ 最近 limit 根（行情/自选列表用 80 根）"]
        SM["searchMeta / searchMetaAsync<br/>→ meta.name / meta.code LIKE"]
        FB --> RUN["runBarsQuery<br/>date · open · high · low · close · vol · amo"]
        FL --> RUN
        RUN --> OUT["[KlineItem] 序列 → 图表引擎 / 行情表"]
    end
    DOC --> QRY
```

