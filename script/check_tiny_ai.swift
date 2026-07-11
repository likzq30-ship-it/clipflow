import Foundation

@main
struct TinyAICheck {
    static func main() {
        let service = TinyLocalAIService.shared
        let categories = [
            CustomCategory(name: "会议", prompt: "会议 项目 纪要"),
            CustomCategory(name: "代码", prompt: "函数 API Swift")
        ]

        assert(service.categorizeContent("明天项目会议需要整理纪要", customCategories: categories) == "会议")
        assert(service.categorizeContent("下午三点同步需求评审，记得带议程", customCategories: categories) == "会议")
        assert(service.categorizeContent("接口返回空数组，先查日志和异常栈", customCategories: categories) == "代码")
        assert(service.rewrite("明天开会讨论项目进度")?.contains("拓写草稿") == true)
        assert(service.rewrite("明天开会讨论项目进度")?.contains("背景") == true)
        assert(service.rewrite("明天开会讨论项目进度")?.contains("议程") == true)

        print("tiny ai checks passed")
    }
}
