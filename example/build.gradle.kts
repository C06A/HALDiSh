plugins {
    // Not strictly needed, but keeps a standard module
    kotlin("jvm") version "2.0.21"
}

repositories {
    mavenCentral()
    // (Optional while artifact is a SNAPSHOT)
    maven("https://s01.oss.sonatype.org/content/repositories/snapshots/") {
        mavenContent { snapshotsOnly() }
    }
}

// Resolvable configuration to fetch the .sh
val haldish by configurations.creating {
    isCanBeConsumed = false
    isCanBeResolved = true
    isVisible = false
}

dependencies {
    // IMPORTANT: @sh makes Gradle fetch the .sh artifact
    haldish("com.helpchoice.hal:haldish:1.0.0-SNAPSHOT@sh")
}

val halWorkingDir = layout.buildDirectory.dir("haldish")

val runHaldish by tasks.registering {
    group = "example"
    description = "Resolve haldish.sh and execute it with workingDir=build/haldish."
    inputs.files(haldish)
    outputs.dir(halWorkingDir)

    doLast {
        val script = haldish.resolve().single().absoluteFile
        halWorkingDir.get().asFile.mkdirs()
        // Execute FROM CACHE (no copying), but with working dir set to build/haldish
        exec {
            workingDir(halWorkingDir)
            // Using bash avoids relying on exec bit in cache
            commandLine("bash", script.absolutePath, "--hello", "from-example")
        }
    }
}

tasks.named("build") {
    dependsOn(runHaldish)
}
