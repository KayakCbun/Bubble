import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

func expectContains(_ haystack: String, _ needle: String, _ message: String) {
    expect(haystack.contains(needle), "\(message)\n---\n\(haystack)\n---")
}

@main
struct ProseCheck {
    static let wall = "看完了整个工单群（8/13建单 →8/21 最新回复），这个问题的来龙去脉已经基本查清了：## 问题现象海尔租户的 Base（多维表格）自动化「推送仪表盘到群」，消息模板里**手写工号** `<at id=工号></at>` 来 @ 人。5 个工号中4 个（00593200 /01324488 /01043503 /00091916）都能正常 @，唯独 **22025220** @ 后显示为空。##排查链路（三方接力）1. **Base 乔戈亚**：`lark.im.openapi` 发送时4 个工号都转成了19 位 user_id，只有 `22025220`原样留下，日志 `failLocalOfMetas=[EntityType_USER:1, IDs=(22025220)]`2. **飞书 Oncall机器人**（李文静 →江锐）：定位到 `lark.oapi.card`转换层报 `transformerUser user info not exist, larkID:22025220`；目录 facade返回了错误映射 `22025220 →22025220`3. **Base 自动化 RD（卞晓栋）最终定性**（8/19）： - Base 自动化发送前会把 `<at id>` 的值尝试转成 open_id - **0 开头的工号**：转换失败 → 自动化忽略错误、原样传工号 → 卡片层用 employee_id 解析成功 → @ 正常 - **22025220（2 开头）**：被“成功”转换成了一个**错误的 open_id**（`ou_ea6e9e9ebae5f0b152dc6fedcd74cc9a`）→ 卡片层查不到该用户 → @渲染为空所以根因是：**工号恰好被自动化误转换成无效 open_id**，不是群成员、权限或通讯录问题（这些都已排除）。## 当前状态与方案-工单状态：**[RD待处理]**，已转回 Base/自动化线（郑洁）- **用户侧绕过方案**（8/21卞晓栋最新回复）：消息体里别写工号，把 at 的 id换成 **lark_id**（该用户 user_id = `7096308547608133660`；获取方式：打开 debug模式右键复制），或改成引用人员字段- **产品侧待跟进**：自动化对 employee_id输入的转换逻辑应跳过/校验（卞晓栋已 @胡明煜讨论，因为之前有 id 类型导致卡片更新失败的先例，需要谨慎改）需要我帮你把这个结论整理成一段话发到群里，或者跟进后续 RD侧的修复进展吗？"

    static let checklist = "这条看起来是待排查的工单，我先给出最常见的排查清单——飞书群里 @不到人，基本就这几种原因：**1. 用的是“文本模拟@”而非真实@**- 直接拼字符串 `@张三` 只是纯文本，不会产生真实提醒。-必须用富文本/Post消息的 `at` 元素，或文本消息里的 `<at user_id=\"ou_xxx\"></at>` 占位，交互卡片则要在卡片中用 at组件。**2. user_id 类型不匹配（最常见）**- `open_id` / `user_id` / `union_id` 三种不能混用。消息 at 元素里的 `user_id` 字段要和请求参数 `key_type`（或元素内指定）一致。-建议统一用 `open_id`。**3.被人是“外部用户”或跨租户**- 对方如果是外部联系人/别的租户的人，机器人可能拿不到其 open_id，@不会生效。**4. 成员不在群里 / 已离职停用**- @ 的前提是在群内；账号停用后 at 元素会静默降级为文本。**5.机器人权限**-缺少获取群成员信息、或发送消息相关 scope 时，部分场景 at会被吞掉。---要继续往下定位，需要你补充几个信息："

    static func main() {
        testCodeTokens()
        testWallReflow()
        testChecklistReflow()
        testCodeSpanProtected()
        testEmphasisBoundaryWhitespace()
        testBoldNumberedTitles()
        testKinsokuWrap()
        testTableReflow()
        testCodeDisplayChunks()
        print("PASS: prose reflow and code tokens")
    }

    static func testCodeDisplayChunks() {
        let source = Array(repeating: "let stableRow = true\n", count: 2_000).joined()
        let chunks = CodeDisplayChunker.chunks(source)
        expect(chunks.count > 4, "very long code is split into stable display rows")
        expect(chunks.joined() == source, "code display chunking is lossless")
        let grown = source + "let liveTail = true\n"
        let grownChunks = CodeDisplayChunker.chunks(grown)
        expect(
            Array(grownChunks.prefix(chunks.count - 1)) == Array(chunks.prefix(chunks.count - 1)),
            "streaming code preserves every completed display chunk"
        )
    }

    static func testCodeTokens() {
        expect(CodeToken.leading("open_id") == "open_id", "snake_case")
        expect(CodeToken.leading("employee_id输入") == "employee_id", "snake_case before CJK")
        expect(CodeToken.leading("lark.im.openapi") == "lark.im.openapi", "dotted ident")
        expect(CodeToken.leading("lark.oapi.card") == "lark.oapi.card", "dotted ident 2")
        expect(CodeToken.leading("00593200 /x") == "00593200", "employee id")
        expect(CodeToken.leading("8/13") == nil, "do not chip dates")
        expect(CodeToken.leading("/new ") == "/new", "slash command")
        expect(CodeToken.leading("/clear") == "/clear", "slash command 2")
        expect(CodeToken.leading("<at id>") == "<at id>", "tag")
        expect(CodeToken.leading("[RD待处理]，") == "[RD待处理]", "status tag")
        expect(CodeToken.leading("ou_ea6e9e9ebae5f0b152dc6fedcd74cc9a")?.hasPrefix("ou_") == true, "open id")
        expect(CodeToken.looksLike("lark_id"), "looksLike snake")
        expect(CodeToken.looksLike("22025220"), "looksLike digits")
        expect(CodeToken.looksLike("[RD待处理]"), "looksLike status")
        expect(!CodeToken.looksLike("手写工号"), "not chinese phrase")
        expect(!CodeToken.looksLike("用户侧绕过方案"), "not heading phrase")
        let sample = "转成 open_id - 卡片层用 employee_id 解析 user_id = 00593200"
        var found: [String] = []
        var rest = sample
        while let range = CodeToken.nextRange(in: rest) {
            found.append(String(rest[range]))
            rest = String(rest[range.upperBound...])
        }
        expect(found.contains("open_id"), "scan open_id \(found)")
        expect(found.contains("employee_id"), "scan employee_id \(found)")
        expect(found.contains("user_id"), "scan user_id \(found)")
        expect(found.contains("00593200"), "scan employee number \(found)")
        let emphasis = "工号恰好被自动化误转换成无效 open_id"
        expect(CodeToken.nextRange(in: emphasis).map { String(emphasis[$0]) } == "open_id", "chip inside bold phrase")
        expect(!CodeToken.looksLike(emphasis), "whole bold phrase is not a code token")
    }

    static func testWallReflow() {
        let text = ProseReflow.reflow(wall)
        expectContains(text, "\n## 问题现象\n", "heading 问题现象")
        expectContains(text, "\n## 排查链路（三方接力）\n", "heading 排查链路")
        expectContains(text, "\n## 当前状态与方案\n", "heading 当前状态")
        expectContains(text, "\n1. ", "numbered 1")
        expectContains(text, "\n2. ", "numbered 2")
        expectContains(text, "\n3. ", "numbered 3")
        expectContains(text, "\n- 工单状态", "bullet 工单状态")
        expectContains(text, "\n- **用户侧绕过方案**", "bullet 绕过方案")
        expectContains(text, "\n- **产品侧待跟进**", "bullet 产品侧")
        expectContains(text, "\n所以根因是", "conclusion break")
        expectContains(text, "\n需要我帮你", "cta break")
        expectContains(text, "`<at id=工号></at>`", "keep code span")
        expectContains(text, "`lark.im.openapi`", "keep dotted code span")
        expect(!text.contains("：##"), "heading not glued to colon")
        expect(text.contains("\n"), "reflow inserts newlines")
        if ProcessInfo.processInfo.environment["DUMP"] != nil {
            fputs(text + "\n", stdout)
        }
    }

    static func testChecklistReflow() {
        let text = ProseReflow.reflow(checklist)
        expectContains(text, "\n1. ", "checklist 1")
        expectContains(text, "\n2. ", "checklist 2")
        expectContains(text, "\n---\n", "horizontal rule")
        expectContains(text, "\n要继续往下", "continue break")
        expectContains(text, "`open_id`", "keep open_id span")
        expectContains(text, "`@张三`", "keep at span")
    }

    static func testCodeSpanProtected() {
        let text = ProseReflow.reflow("前面`<at id=工号>## 不是标题</at>`后面。## 问题现象后面是一段足够长的正文内容")
        expectContains(text, "`<at id=工号>## 不是标题</at>`", "hashes inside code stay put")
        expectContains(text, "\n## 问题现象\n", "real heading still splits")
    }

    static func testEmphasisBoundaryWhitespace() {
        let runs = MarkdownEmphasis.runs(for: "边界划得很干净，状态机经过推演。 ")
        expect(runs == [.strong("边界划得很干净，状态机经过推演。"), .text(" ")], "move trailing space outside the semantic bold run \(runs)")

        let multiline = MarkdownEmphasis.runs(for: "第一句。\n第二句。\u{3000}")
        expect(multiline == [.strong("第一句。\n第二句。"), .text("\u{3000}")], "newlines and Chinese punctuation remain inside bold \(multiline)")
        expect(
            InlineRun.strong("一段很长的中文句子。").replacingText(with: "句子后半段。") == .strong("句子后半段。"),
            "line wrapping preserves strong semantics instead of splitting Markdown delimiters"
        )
        expect(MarkdownEmphasis.runs(for: " ") == [.text("** **")], "empty emphasis stays literal")

        let source = "**边界划得很干净。\n但数据库风险仍需解决。 **后文"
        let span = MarkdownEmphasis.consumeLeading(in: source)
        expect(span?.inner == "边界划得很干净。\n但数据库风险仍需解决。 ", "consume the complete multiline emphasis from source Markdown")
        expect(span?.remainder == "后文", "leave following prose outside the emphasis")
        expect(
            span.map { MarkdownEmphasis.runs(for: $0.inner) }
                == [.strong("边界划得很干净。\n但数据库风险仍需解决。"), .text(" ")],
            "the production delimiter seam emits semantic strong text with trailing whitespace outside"
        )
    }

    static func testBoldNumberedTitles() {
        let source = """
        ## 主要风险，按严重度排

        **1. 多维表格是唯一存储（10.1、9.3）。** 业务数据、全量版本都在 Base。

        **2. 检索快照同步保存门槛（5.4）。** 每次在线检索必须先写完快照再返回。
        """
        let rendered = ProseReflow.reflow(source)
        expectContains(rendered, "\n1. **多维表格是唯一存储（10.1、9.3）。** 业务数据", "preserve the first bold numbered title")
        expectContains(rendered, "\n2. **检索快照同步保存门槛（5.4）。** 每次在线检索", "preserve the second bold numbered title")
        expect(!rendered.contains("\n**\n"), "do not leave an orphan emphasis marker\n---\n\(rendered)\n---")
        expect(!rendered.contains("。 **"), "do not move closing emphasis after punctuation\n---\n\(rendered)\n---")
    }

    static func testKinsokuWrap() {
        expect(ProseWrap.cannotStart("。"), "ideographic period cannot start a line")
        expect(ProseWrap.cannotStart("，"), "ideographic comma cannot start a line")
        expect(ProseWrap.isGlueRun("。"), "period-only run glues")
        expect(ProseWrap.isGlueRun(" 。"), "spaced period glues")
        expect(!ProseWrap.isGlueRun("行。"), "text plus period is not glue-only")
        let glued = ProseWrap.glue("9156 行", tail: "。去查")
        expect(glued.0 == "9156 行。", "period stays on the previous line \(glued.0)")
        expect(glued.1 == "去查", "rest continues after the glued period \(glued.1)")
        let short = ProseReflow.reflow("9156 行。")
        expect(short == "9156 行。", "short Chinese answer is not reflowed into extra lines \(short.debugDescription)")
        let sentence = ProseReflow.reflow("我去查这张表是不是同步表。")
        expect(sentence == "我去查这张表是不是同步表。", "plain Chinese sentence stays one block \(sentence.debugDescription)")
        expect(!sentence.contains("\n"), "plain Chinese sentence has no inserted newline")
    }

    static func testTableReflow() {
        let table = """
        1. 哪次同步
        | 项 | 值 |
        | --- | --- |
        | 类型 | bitable_connector |
        | 同步方式 | periodic |
        """
        let text = ProseReflow.reflow(table)
        expectContains(text, "| 项 | 值 |", "keep table header")
        expectContains(text, "| --- | --- |", "keep table separator")
        expectContains(text, "| 类型 | bitable_connector |", "keep table body")
        expect(!text.contains("\n---\n\n"), "table dashes are not turned into a horizontal rule")
        let compact = ProseReflow.reflow("|项|值|\n|-|-|\n|类型|foo|")
        expectContains(compact, "|项|值|", "compact table header survives")
        expectContains(compact, "|类型|foo|", "compact table body survives")
    }
}
