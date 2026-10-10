import Foundation

// No store is instantiated or user data read by this executable.
enum AppPaths { static let support = URL(fileURLWithPath: "/tmp/saystuff-unused-dictionary-smoke") }

@main struct DictionaryReplacementSmoke {
    static func main() {
        let entries = [DictionaryEntry(term: "Kcaly", heardAs: ["Kali"]),
                       DictionaryEntry(term: "Groq", heardAs: ["Groc", "Grok"]),
                       DictionaryEntry(term: "Grok")]
        let replace = DictionaryStore.replacer(for: entries)
        assert(replace("Kali, Groc and Grok.") == "Kcaly, Groq and Grok.")
        assert(replace("kali GROC GROK grok") == "Kcaly Groq GROK grok")
        assert(replace("Kalifornia Grocery") == "Kalifornia Grocery")
        let reverse = DictionaryStore.replacer(for: entries.reversed())
        assert(reverse("Kali, Groc and Grok.") == "Kcaly, Groq and Grok.")
        print("PASS: saved aliases apply, canonical names stay distinct, whole words, case and entry order")
    }
}
