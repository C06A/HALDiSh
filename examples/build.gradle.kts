// ─── paths ────────────────────────────────────────────────────────────────────
val examplesDir     = file("src/main/bash")
val haldishInstall  = layout.buildDirectory.get().asFile.resolve("haldish")

// ─── repositories ─────────────────────────────────────────────────────────────

repositories {
    mavenLocal()
    mavenCentral()
}

// ─── HALDiSh archive dependency ───────────────────────────────────────────────

/**
 * Resolve the published groupId the same way the :scripts publication does —
 * mavenCentralNamespace property takes precedence over project.group so that
 * local and CI builds find the artifact regardless of which namespace was used.
 */
val publishedGroup: String = providers.gradleProperty("mavenCentralNamespace")
    .orElse(providers.environmentVariable("MAVEN_CENTRAL_NAMESPACE"))
    .orElse(project.group.toString()).get()

/**
 * Dedicated configuration for the HALDiSh self-inflatable archive (.run).
 * Using a separate configuration avoids polluting the compile/runtime classpaths
 * and lets Gradle cache and up-to-date-check the download independently.
 */
val haldish: Configuration by configurations.creating

dependencies {
    haldish("$publishedGroup:${rootProject.name.lowercase()}:${version}@run")
}

// ─── setup ────────────────────────────────────────────────────────────────────

/**
 * Downloads the HALDiSh archive from Maven Central (if not already cached by
 * Gradle) and installs it into examples/build/haldish/ by running the archive
 * with --prefix.  Example scripts should set HAL_LIB_DIR to this directory.
 */
tasks.register("installHaldish") {
    group       = "setup"
    description = "Downloads and installs the HALDiSh archive from Maven Central into build/haldish/."

    inputs.files(haldish)
    outputs.dir(haldishInstall)

    doLast {
        haldishInstall.mkdirs()
        val archive = haldish.singleFile
        project.exec {
            commandLine("bash", archive.absolutePath, "--prefix", haldishInstall.absolutePath)
        }
        logger.lifecycle("HALDiSh installed to: $haldishInstall")
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
    dependsOn("installHaldish", "check")
}

tasks.register<Delete>("clean") {
    group       = "build"
    description = "Deletes the build directory."
    delete(layout.buildDirectory)
}
