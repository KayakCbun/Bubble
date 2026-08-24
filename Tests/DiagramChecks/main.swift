import BeautifulMermaid
import BubbleDiagramSupport
import Foundation

let fullBitableDiagram = """
flowchart TB  subgraph clients["客户端"]
  WEB[Web / 桌面] MOB[移动端]
  FORM[分享表单]
  OPENAPI[OpenAPI / SDK]
  CONN[连接器 / 同步] end

subgraph edge["接入"]
  GW[API Gateway / BFF]
  RL[限流 /配额入口]
  AUTH[登录 / 租户 / 应用身份] end

subgraph collab["协作面"]
  PRES[在线状态 / 光标]
  OT[OT / CRDT 协同]
  LOCK[单元格 / 记录锁]
  EVT[变更事件总线] end

subgraph core["表格核"]
  APP[应用 / 表 / 视图元数据]
  REC[记录存储]
  FIELD[字段类型系统<br/>文本 / 单选 / 人员 / 附件 / 关联]
  LINK[跨表关联]
  LOOKUP[Lookup / Rollup]
  FORMULA[公式引擎]
  VIEW[视图查询<br/>网格 / 看板 / 甘特 /画册 / 日历]    FILTER[筛选 / 分组 / 排序 /颜色] end

subgraph perm["权限"] APPACL[应用角色]
  TBLACL[表 / 字段权限]
  ROWACL[行级权限 / 高级权限]
  SHARE[分享链接 / 公开表单]
end subgraph compute["计算与索引"]
  DEP[公式依赖图]
  RECALC[增量重算]
  IDX[(倒排 / 检索)]
  STAT[聚合 / 仪表盘]
  QUOTA[行数 / 附件 / 自动化配额]
end

subgraph auto["自动化"]
  TRIGGER[触发器<br/>增删改 / 定时 / webhook]
  COND[条件]    ACTION[动作<br/>写记录 / 通知 / HTTP / 审批]
  QUEUE[(自动化队列)]
  DLQ[(失败重试 / 死信)]
end  subgraph storage["存储"]
  META[(元数据 DB)]
  ROWDB[(行存 / 宽表 / KV)]
  BLOB[(附件对象存储)]
  BINLOG[(变更日志 / CDC)]
  CACHE[(热视图缓存)]
end

subgraph control["控制面"]
  ADMIN[管理后台]
  AUDIT[(审计)]
  OBS[指标 / 链路 / 告警]
  COPY[应用复制 / 模板]
  OPEN[开放能力 / 事件订阅]
end

WEB --> GW
MOB --> GW
FORM --> GW
OPENAPI --> GW
CONN --> GW
GW --> RL --> AUTH
AUTH --> OT
AUTH --> APPACL
OT --> LOCK --> EVT
PRES --> WEB
EVT --> BINLOG
AUTH --> APP
APP --> REC  REC --> FIELD  FIELD --> LINK --> LOOKUP
FIELD --> FORMULA
FORMULA --> DEP --> RECALC
LOOKUP --> RECALC
RECALC --> REC
APP --> VIEW --> FILTER  FILTER --> ROWDB
VIEW --> CACHE
REC --> ROWDB
APP --> META
FIELD --> BLOB  APPACL --> TBLACL --> ROWACL
SHARE --> FORM
ROWACL --> VIEW
ROWACL --> OPENAPI  EVT --> TRIGGER --> QUEUE --> COND --> ACTION
ACTION --> REC
ACTION --> OPEN
QUEUE -->|失败| DLQ
QUOTA --> REC
QUOTA --> QUEUE
QUOTA --> BLOB
REC --> IDX
FILTER --> STAT
STAT --> CACHE
BINLOG --> IDX
BINLOG --> OPEN
BINLOG --> AUDIT
ADMIN --> APP
ADMIN --> APPACL
COPY --> APP
COPY --> REC
GW --> OBS
QUEUE --> OBS
RECALC --> OBS
"""

let gluedDiagram = fullBitableDiagram
    .components(separatedBy: "\nsubgraph collab")
    .first ?? fullBitableDiagram

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

do {
    let source = MermaidSource.normalize(gluedDiagram)
    let layout = try MermaidRenderer.layout(source)
    if ProcessInfo.processInfo.environment["DUMP"] != nil {
        print(source)
        print("nodes=\(layout.flowchartNodes?.count ?? -1) edges=\(layout.flowchartEdges?.count ?? -1) groups=\(layout.flowchartGroups?.count ?? -1)")
    }
    expect(layout.flowchartNodes?.count == 8, "glued node declarations are split")
    expect(layout.flowchartGroups?.count == 2, "glued subgraph boundaries are split")
    expect(MermaidCanvasAppearance.isOpaqueWhite, "zoom canvas is opaque white")
    let fullLayout = try MermaidRenderer.layout(MermaidSource.normalize(fullBitableDiagram))
    if ProcessInfo.processInfo.environment["DUMP"] != nil {
        print(MermaidSource.normalize(fullBitableDiagram))
        print("full nodes=\(fullLayout.flowchartNodes?.count ?? -1) edges=\(fullLayout.flowchartEdges?.count ?? -1) groups=\(fullLayout.flowchartGroups?.count ?? -1)")
    }
    expect((fullLayout.flowchartNodes?.count ?? 0) >= 40, "full bitable diagram keeps its nodes")
    expect((fullLayout.flowchartEdges?.count ?? 0) >= 40, "full bitable diagram keeps its edges")
    expect(fullLayout.flowchartGroups?.count == 9, "full bitable diagram keeps every subgraph")
    print("PASS: diagram normalization and canvas appearance")
} catch {
    FileHandle.standardError.write(Data("FAIL: diagram did not render: \(error)\n".utf8))
    exit(1)
}
