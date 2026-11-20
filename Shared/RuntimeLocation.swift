// The fork has its own installation and launchd namespace. Apple's container
// package can update /usr/local independently of Boxling.
let forkInstallRoot = "/Library/Application Support/MyBox/Runtime"
let forkPackageIdentifier = "io.github.janpmz.my-container-box.runtime"
let myboxPackageIdentifier = "io.github.janpmz.mybox"
let forkServicePrefix = "io.github.janpmz.mybox.runtime."
let privateServiceAccount = "_boxling"
let legacyPrivateServiceAccount = "_mybox"
let privateServiceHome = "/private/var/db/mybox-runtime"
let forkBootPlugin = forkInstallRoot + "/libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux"

let namePrefix = "mybox-"
let managedLabel = "io.github.janpmz.my-container-box.managed"

func managedBoxName(id: String, configuration: [String: Any]) -> String? {
    let labels = configuration["labels"] as? [String: String]
    guard labels?[managedLabel] == "true", id.hasPrefix(namePrefix) else { return nil }
    let name = String(id.dropFirst(namePrefix.count))
    return matches(name, "^[a-z][a-z0-9-]{0,47}$") ? name : nil
}
