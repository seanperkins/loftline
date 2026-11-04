/// A font every test machine has. Liberation Sans has Helvetica's metrics; Linux CI installs it (scripts/linux.sh, ci.yml).
#if os(Windows)
let testFont = "Arial"
#elseif canImport(CoreText)
let testFont = "Helvetica"
#else
let testFont = "Liberation Sans"
#endif
