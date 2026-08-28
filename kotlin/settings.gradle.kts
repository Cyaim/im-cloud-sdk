pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
}

// Deliberately a standalone Gradle build rather than a subproject of anything else: the SDK is
// published on its own cadence and consumed by tenant apps that know nothing about this repo.
rootProject.name = "im-client-kotlin"
