rootProject.name = "freenet-appkit-android"

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

// The Kotlin library that wraps the UniFFI bindings and the WebView host
// helpers, and the demo app built on it.
include(":appkit", ":demo")
