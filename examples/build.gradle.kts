// ─── paths ────────────────────────────────────────────────────────────────────
val examplesDir     = file("src/main/bash")

val haldish: Configuration by configurations.creating

repositories {
    mavenLocal()
    mavenCentral()
}

dependencies {
    haldish("com.helpchoice:haldish:2.2.2@run")
}

tasks.register("setup") {
    group = "build"
    dependsOn(haldish)
    inputs.files(haldish)
    outputs.dir(layout.buildDirectory.dir("haldish"))
    doLast {
        val runFile = haldish.singleFile
        runFile.setExecutable(true)
        exec {
            commandLine(runFile.absolutePath, "--prefix", layout.buildDirectory.dir("haldish").get().asFile.absolutePath)
        }
    }
}

// ─── lifecycle ────────────────────────────────────────────────────────────────

/**
 * Runs every example script in src/main/bash/ with bash -n (syntax check)
 * so CI can verify they at least parse correctly.
 */
tasks.register<Exec>("check") {
    group       = "verification"
    description = "Syntax-checks all example bash scripts."

    commandLine("bash", "-c", """
        set -euo pipefail
        ERRORS=0
        for f in "${examplesDir}"/*.sh; do
            printf 'Checking %s … ' "${'$'}f"
            if bash -n "${'$'}f"; then
                echo OK
            else
                echo FAIL
                ERRORS=${'$'}((ERRORS + 1))
            fi
        done
        exit ${'$'}ERRORS
    """.trimIndent())
}

tasks.register("build") {
    group       = "build"
    description = "Assembles and checks this project."
    dependsOn("setup", "check")
}

tasks.register<Delete>("clean") {
    group       = "build"
    description = "Deletes the build directory."
    delete(layout.buildDirectory)
}
