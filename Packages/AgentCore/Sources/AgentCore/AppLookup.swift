import Foundation

/// An app the phone can launch.
public struct InstalledApp: Sendable, Hashable, Codable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Finds an app's bundle id by its name ("WeChat", "微信", "Settings"), so the model never guesses bundle ids.
///
/// Sources, in order: the apps installed on the phone (when the driver can list them), then a bundled catalog of
/// Apple's built-in apps and popular apps. The catalog comes from iphone-use (MIT, github.com/leeguooooo/iphone-use,
/// `crates/server/src/app_lookup.rs` and `apps_catalog.json`, verified 2026-10-10); a catalog hit is a candidate,
/// not proof the app is installed.
public enum AppLookup {
    public struct Candidate: Sendable, Equatable {
        public var bundleID: String
        public var name: String
        /// true: on the phone's app list; false: not on it; nil: unknown (no list, catalog only).
        public var installed: Bool?
        /// The query equals the name, an alias, or the bundle id.
        public var exact: Bool

        public var display: String {
            let state = installed == true ? "installed" : installed == false ? "not installed" : "from catalog"
            return "\(name) (\(bundleID), \(state))"
        }
    }

    /// Candidates for `query`, exact matches first; partial matches are dropped when there is an exact one.
    public static func find(_ query: String, installed: [InstalledApp]) -> [Candidate] {
        let wanted = key(query)
        guard !wanted.isEmpty else { return [] }
        let listed = Set(installed.map(\.bundleID))
        var results: [String: Candidate] = [:]
        var order: [String] = []

        func consider(bundleID: String, name: String, aliases: [String], fromPhone: Bool) {
            let names = [name] + aliases
            let exact = key(bundleID) == wanted || names.contains { key($0) == wanted }
            let partial = wanted.count >= 2 && names.contains { key($0).contains(wanted) || (key($0).count >= 2 && wanted.contains(key($0))) }
            guard exact || partial else { return }
            let isInstalled: Bool? = installed.isEmpty ? nil : (fromPhone || listed.contains(bundleID))
            if var existing = results[bundleID] {
                existing.exact = existing.exact || exact
                if existing.installed == nil { existing.installed = isInstalled }
                results[bundleID] = existing
            } else {
                results[bundleID] = Candidate(bundleID: bundleID, name: name, installed: isInstalled, exact: exact)
                order.append(bundleID)
            }
        }

        for app in installed { consider(bundleID: app.bundleID, name: app.name, aliases: [], fromPhone: true) }
        for entry in systemApps + catalog {
            consider(bundleID: entry.bundleID, name: entry.name, aliases: entry.aliases, fromPhone: false)
        }
        var candidates = order.compactMap { results[$0] }
        if candidates.contains(where: \.exact) { candidates = candidates.filter(\.exact) }
        // Installed first, then unknown, then known missing.
        func rank(_ c: Candidate) -> Int { c.installed == true ? 0 : c.installed == nil ? 1 : 2 }
        return candidates.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// The one app `query` names, when it is unambiguous: a single exact match not known to be missing.
    public static func resolve(_ query: String, installed: [InstalledApp]) -> Candidate? {
        let exact = find(query, installed: installed).filter { $0.exact && $0.installed != false }
        let onPhone = exact.filter { $0.installed == true }
        if onPhone.count == 1 { return onPhone[0] }
        return exact.count == 1 ? exact[0] : nil
    }

    /// The display name for a bundle id from the catalog.
    public static func name(forBundleID bundleID: String) -> String? {
        (systemApps + catalog).first { $0.bundleID == bundleID }?.name
    }

    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { !$0.isWhitespace && $0 != "-" && $0 != "·" }
    }

    struct AppEntry: Sendable {
        var bundleID: String
        var name: String
        var aliases: [String]

        init(_ bundleID: String, _ name: String, _ aliases: [String]) {
            self.bundleID = bundleID
            self.name = name
            self.aliases = aliases
        }
    }

    /// Apple's built-in apps (bundle ids read from a real iPhone's inventory).
    static let systemApps: [AppEntry] = [
        AppEntry("com.apple.Preferences", "Settings", ["设置", "设定"]),
        AppEntry("com.apple.mobilesafari", "Safari", ["浏览器", "Safari浏览器"]),
        AppEntry("com.apple.MobileSMS", "Messages", ["信息", "短信", "iMessage"]),
        AppEntry("com.apple.mobileslideshow", "Photos", ["照片", "相册"]),
        AppEntry("com.apple.camera", "Camera", ["相机"]),
        AppEntry("com.apple.mobiletimer", "Clock", ["时钟", "闹钟"]),
        AppEntry("com.apple.mobilenotes", "Notes", ["备忘录"]),
        AppEntry("com.apple.reminders", "Reminders", ["提醒事项"]),
        AppEntry("com.apple.mobilecal", "Calendar", ["日历"]),
        AppEntry("com.apple.mobilephone", "Phone", ["电话"]),
        AppEntry("com.apple.mobilemail", "Mail", ["邮件"]),
        AppEntry("com.apple.Maps", "Maps", ["地图", "Apple Maps"]),
        AppEntry("com.apple.AppStore", "App Store", ["应用商店", "appstore"]),
        AppEntry("com.apple.Passbook", "Wallet", ["钱包"]),
        AppEntry("com.apple.Health", "Health", ["健康"]),
        AppEntry("com.apple.DocumentsApp", "Files", ["文件"]),
        AppEntry("com.apple.shortcuts", "Shortcuts", ["快捷指令"]),
        AppEntry("com.apple.Music", "Music", ["音乐", "Apple Music"]),
        AppEntry("com.apple.findmy", "Find My", ["查找"]),
        AppEntry("com.apple.calculator", "Calculator", ["计算器"]),
        AppEntry("com.apple.MobileAddressBook", "Contacts", ["通讯录", "联系人"]),
        AppEntry("com.apple.facetime", "FaceTime", ["FaceTime通话"]),
        AppEntry("com.apple.weather", "Weather", ["天气"]),
        AppEntry("com.apple.iBooks", "Books", ["图书", "Apple Books"]),
        AppEntry("com.apple.podcasts", "Podcasts", ["播客"]),
        AppEntry("com.apple.tv", "TV", ["Apple TV", "视频"]),
        AppEntry("com.apple.Translate", "Translate", ["翻译"]),
        AppEntry("com.apple.VoiceMemos", "Voice Memos", ["语音备忘录"]),
        AppEntry("com.apple.Home", "Home", ["家庭"]),
        AppEntry("com.apple.Fitness", "Fitness", ["健身"]),
        AppEntry("com.apple.freeform", "Freeform", ["无边记"]),
        AppEntry("com.apple.Bridge", "Watch", ["Apple Watch", "手表"]),
        AppEntry("com.apple.compass", "Compass", ["指南针"]),
        AppEntry("com.apple.measure", "Measure", ["测距仪"]),
        AppEntry("com.apple.Magnifier", "Magnifier", ["放大器"]),
        AppEntry("com.apple.stocks", "Stocks", ["股市"]),
        AppEntry("com.apple.tips", "Tips", ["提示"]),
        AppEntry("com.apple.news", "News", ["Apple News"]),
        AppEntry("com.apple.Passwords", "Passwords", ["密码"]),
        AppEntry("com.apple.journal", "Journal", ["手记"]),
        AppEntry("com.apple.TestFlight", "TestFlight", []),
        AppEntry("com.apple.MobileStore", "iTunes Store", []),
        AppEntry("com.apple.games", "Games", ["游戏"]),
    ]

    /// Popular apps (bundle ids read from Apple's public iTunes lookup API).
    static let catalog: [AppEntry] = [
        AppEntry("com.tencent.xin", "微信", ["WeChat", "Weixin"]),
        AppEntry("com.alipay.iphoneclient", "支付宝", ["Alipay"]),
        AppEntry("com.taobao.taobao4iphone", "淘宝", ["Taobao"]),
        AppEntry("com.360buy.jdmobile", "京东", ["JD", "Jingdong", "JD.com"]),
        AppEntry("com.xunmeng.pinduoduo", "拼多多", ["Pinduoduo", "PDD"]),
        AppEntry("com.xingin.discover", "小红书", ["Xiaohongshu", "RED", "XHS"]),
        AppEntry("com.ss.iphone.ugc.Aweme", "抖音", ["Douyin"]),
        AppEntry("com.jiangjia.gif", "快手", ["Kuaishou"]),
        AppEntry("tv.danmaku.bilianime", "哔哩哔哩", ["bilibili", "B站"]),
        AppEntry("com.sina.weibo", "微博", ["Weibo", "新浪微博"]),
        AppEntry("com.tencent.mqq", "QQ", ["腾讯QQ"]),
        AppEntry("com.tencent.QQMusic", "QQ音乐", ["QQ Music"]),
        AppEntry("com.netease.cloudmusic", "网易云音乐", ["NetEase Cloud Music"]),
        AppEntry("com.baidu.map", "百度地图", ["Baidu Maps"]),
        AppEntry("com.autonavi.amap", "高德地图", ["Amap", "AutoNavi", "高德"]),
        AppEntry("com.xiaojukeji.didi", "滴滴出行", ["滴滴", "DiDi"]),
        AppEntry("com.meituan.imeituan", "美团", ["Meituan"]),
        AppEntry("com.meituan.itakeaway", "美团外卖", ["Meituan Waimai"]),
        AppEntry("me.ele.ios.eleme", "饿了么", ["淘宝闪购", "Ele.me", "Eleme"]),
        AppEntry("com.dianping.dpscope", "大众点评", ["Dianping"]),
        AppEntry("com.taobao.fleamarket", "闲鱼", ["Xianyu", "Idle Fish"]),
        AppEntry("ctrip.com", "携程旅行", ["携程", "Ctrip", "Trip.com CN"]),
        AppEntry("com.taobao.travel", "飞猪", ["飞猪旅行", "Fliggy"]),
        AppEntry("cn.12306.rails12306", "铁路12306", ["12306"]),
        AppEntry("com.baidu.netdisk", "百度网盘", ["Baidu Netdisk"]),
        AppEntry("com.baidu.BaiduMobile", "百度", ["Baidu"]),
        AppEntry("com.quark.browser", "夸克", ["Quark"]),
        AppEntry("com.bot.doubao", "豆包", ["Doubao"]),
        AppEntry("com.zhihu.ios", "知乎", ["Zhihu"]),
        AppEntry("com.ss.iphone.article.News", "今日头条", ["头条", "Toutiao"]),
        AppEntry("com.qiyi.iphone", "爱奇艺", ["iQIYI"]),
        AppEntry("com.tencent.live4iphone", "腾讯视频", ["Tencent Video"]),
        AppEntry("com.youku.YouKu", "优酷", ["优酷视频", "Youku"]),
        AppEntry("com.tencent.weread", "微信读书", ["WeRead"]),
        AppEntry("com.tencent.qqmail", "QQ邮箱", ["QQ Mail"]),
        AppEntry("com.tencent.meeting", "腾讯会议", ["Tencent Meeting", "VooV"]),
        AppEntry("com.laiwang.DingTalk", "钉钉", ["DingTalk"]),
        AppEntry("com.bytedance.ee.lark", "飞书", ["Feishu"]),
        AppEntry("com.tencent.ww", "企业微信", ["WeCom", "WeChat Work"]),
        AppEntry("com.cmbchina.MPBBank", "招商银行", ["招行", "CMB", "China Merchants Bank"]),
        AppEntry("com.cmbchina.cmblife", "掌上生活", ["招商银行信用卡", "CMB Life"]),
        AppEntry("com.icbc.iphoneclient", "中国工商银行", ["工商银行", "工行", "ICBC"]),
        AppEntry("com.ccb.ccbDemo", "中国建设银行", ["建设银行", "建行", "CCB"]),
        AppEntry("com.bankabc.iphonerelease", "中国农业银行", ["农业银行", "农行", "ABC Bank"]),
        AppEntry("com.boc.BOCMBCI", "中国银行", ["中行", "Bank of China", "BOC"]),
        AppEntry("com.xueqiu", "雪球", ["Xueqiu", "Snowball"]),
        AppEntry("cn.com.10jqka.IHexin", "同花顺", ["Tonghuashun", "10jqka"]),
        AppEntry("com.eastmoney.iphone", "东方财富", ["Eastmoney"]),
        AppEntry("cn.futu.FutuTraderPhone", "富途牛牛", ["富途", "Futu", "moomoo HK"]),
        AppEntry("jp.pay2.app.ios", "PayPay", ["ペイペイ"]),
        AppEntry("jp.naver.line", "LINE", ["ライン"]),
        AppEntry("net.whatsapp.WhatsApp", "WhatsApp", ["WhatsApp Messenger"]),
        AppEntry("com.burbn.instagram", "Instagram", ["IG"]),
        AppEntry("com.facebook.Facebook", "Facebook", ["FB"]),
        AppEntry("com.facebook.Messenger", "Messenger", ["Facebook Messenger"]),
        AppEntry("com.burbn.barcelona", "Threads", []),
        AppEntry("com.atebits.Tweetie2", "X", ["Twitter"]),
        AppEntry("ph.telegra.Telegraph", "Telegram", ["Telegram Messenger"]),
        AppEntry("org.whispersystems.signal", "Signal", []),
        AppEntry("com.google.ios.youtube", "YouTube", ["油管"]),
        AppEntry("com.google.GoogleMobile", "Google", ["谷歌"]),
        AppEntry("com.google.Gmail", "Gmail", []),
        AppEntry("com.google.Maps", "Google Maps", ["谷歌地图"]),
        AppEntry("com.google.chrome.ios", "Chrome", ["Google Chrome"]),
        AppEntry("com.spotify.client", "Spotify", []),
        AppEntry("com.netflix.Netflix", "Netflix", []),
        AppEntry("com.zhiliaoapp.musically", "TikTok", []),
        AppEntry("com.ubercab.UberClient", "Uber", []),
        AppEntry("com.amazon.Amazon", "Amazon", ["Amazon Shopping", "亚马逊"]),
        AppEntry("com.airbnb.app", "Airbnb", ["爱彼迎"]),
        AppEntry("com.tinyspeck.chatlyio", "Slack", []),
        AppEntry("us.zoom.videomeetings", "Zoom", ["Zoom Workplace"]),
        AppEntry("com.hammerandchisel.discord", "Discord", []),
        AppEntry("com.microsoft.Office.Outlook", "Outlook", ["Microsoft Outlook"]),
        AppEntry("com.microsoft.skype.teams", "Microsoft Teams", ["Teams"]),
        AppEntry("notion.id", "Notion", []),
        AppEntry("com.openai.chat", "ChatGPT", []),
        AppEntry("com.anthropic.claude", "Claude", ["Claude by Anthropic"]),
        AppEntry("com.larksuite.lark", "Lark", ["Lark Suite"]),
    ]
}
