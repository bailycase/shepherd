import ShepherdProtocol
import Testing

@Suite("Design specimen documents")
struct DesignSpecimenDocumentTests {
    @Test func completeDocumentsPreserveThemeAndResourceMarkup() throws {
        let document = try #require(DesignSpecimenDocument("""
            <!doctype html><HTML lang="en" data-theme="dark"><head>
            <style>.sample::before { content: "<body>"; }</style>
            <link rel="stylesheet" href="../component.css">
            </head><body class="sample-theme" data-note="a > b"><button>Sample</button></body></HTML>
            """))
        #expect(document.html == "<HTML lang=\"en\" data-theme=\"dark\">")
        #expect(document.body == "<body class=\"sample-theme\" data-note=\"a > b\">")
        #expect(document.content == "<button>Sample</button>")
        #expect(document.head.contains("content: \"<body>\""))
        #expect(document.head.contains("href=\"../component.css\""))
        #expect(!document.head.contains("<head>") && !document.head.contains("</head>"))
    }

    @Test func omittedHeadTagsAndCommentsDoNotLoseDocumentStyles() throws {
        let document = try #require(DesignSpecimenDocument("""
            <html><!-- <body class="wrong"> --><link rel="stylesheet" href="./sample.css">
            <body class="theme"><input value="Sample"></body></html>
            """))
        #expect(document.body == "<body class=\"theme\">")
        #expect(document.head.contains("href=\"./sample.css\""))
        #expect(document.content == "<input value=\"Sample\">")
        #expect(DesignSpecimenDocument("<button>Fragment</button>") == nil)
    }
}
