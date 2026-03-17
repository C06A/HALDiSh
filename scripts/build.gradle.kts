import java.util.Base64

// ─── paths ────────────────────────────────────────────────────────────────────
val srcDir      = file("src/main/bash")
val testDir     = file("src/test/bats")
val buildBase   = layout.buildDirectory.get().asFile
val batsInstall = buildBase.resolve("bats")
val batsExe     = buildBase.resolve("bats/bin/bats")
val distDir     = buildBase.resolve("dist")
val archiveName = "${rootProject.name}-${version}.run"

// ─── setup ────────────────────────────────────────────────────────────────────

/**
 * Downloads and installs bats-core into scripts/build/bats/.
 * Skipped automatically when bats is already present.
 */
tasks.register<Exec>("installBats") {
    group       = "setup"
    description = "Downloads and installs bats-core test framework locally."

    onlyIf { !batsExe.exists() }

    commandLine("bash", "-c", """
        set -euo pipefail
        BATS_VERSION="1.10.0"
        WORK_DIR=${'$'}(mktemp -d)
        trap 'rm -rf "${'$'}WORK_DIR"' EXIT

        echo "Downloading bats-core ${'$'}{BATS_VERSION}…"
        curl -fsSL "https://github.com/bats-core/bats-core/archive/refs/tags/v${'$'}{BATS_VERSION}.tar.gz" \
            | tar -xzf - --strip-components=1 -C "${'$'}WORK_DIR"

        echo "Installing bats-core to ${batsInstall}…"
        mkdir -p "${batsInstall}"
        "${'$'}WORK_DIR/install.sh" "${batsInstall}"
        echo "Done."
    """.trimIndent())
}

// ─── test ─────────────────────────────────────────────────────────────────────

/**
 * Runs all BATS unit tests found under src/test/bats/.
 * Reports are written to build/test-results/ (TAP format).
 */
tasks.register<Exec>("test") {
    group       = "verification"
    description = "Runs BATS unit tests for bash scripts."

    dependsOn("installBats")

    val resultsDir = buildBase.resolve("test-results")

    doFirst {
        resultsDir.mkdirs()
    }

    environment("SCRIPTS_DIR", srcDir.absolutePath)

    // Run all *.bats files; --tap writes TAP output, --report-formatter junit
    // requires bats ≥ 1.7 — fall back to tap for broader compatibility.
    commandLine("bash", "-c", """
        set -euo pipefail
        BATS_EXE="${batsExe}"
        RESULTS_DIR="${resultsDir}"

        "${'$'}BATS_EXE" \
            --recursive \
            --formatter tap \
            --output "${'$'}RESULTS_DIR" \
            "${testDir}"
    """.trimIndent())
}

// ─── assemble / dist ──────────────────────────────────────────────────────────

/**
 * Packages all scripts from src/main/bash/ into a self-inflatable shell
 * archive (*.run).  The archive is created by:
 *
 *   1. Collecting all *.sh files into a tar.gz payload.
 *   2. Base64-encoding the payload.
 *   3. Prepending a pure-bash self-extraction header.
 *
 * The resulting <name>-<version>.run file can be distributed as-is and
 * executed with:   bash HALDiSh-0.1.0.run [--prefix /install/path]
 */
tasks.register("assembleDist") {
    group       = "build"
    description = "Builds the self-inflatable shell archive (.run)."

    inputs.dir(srcDir)
    outputs.dir(distDir)

    doLast {
        distDir.mkdirs()

        val payloadTar  = buildBase.resolve("payload.tar.gz")
        val archiveFile = distDir.resolve(archiveName)

        // 1 – create tar.gz of all scripts
        project.exec {
            workingDir(srcDir)
            commandLine("bash", "-c",
                "tar -czf '${payloadTar}' ${'$'}(find . -name '*.sh' | sort)")
        }

        // 2 – build the self-extracting file:
        //     header + base64-encoded payload
        val header  = file("src/packaging/_archive_header.sh").readText()
        val payload = Base64.getEncoder().encodeToString(payloadTar.readBytes())

        archiveFile.writeText(
            header +
            "\n# __PAYLOAD_CHECKSUM__ ${'$'}(echo '${payload}' | base64 -d | md5)\n" +
            "__PAYLOAD_BEGIN__\n" +
            payload + "\n"
        )

        archiveFile.setExecutable(true)
        payloadTar.delete()

        println("Archive written to: ${archiveFile}")
    }
}

tasks.register("assemble") {
    group       = "build"
    description = "Assembles the outputs of this project."
    dependsOn("assembleDist")
}

tasks.register("build") {
    group       = "build"
    description = "Assembles and tests this project."
    dependsOn("assemble", "test")
}

tasks.register<Delete>("clean") {
    group       = "build"
    description = "Deletes the build directory."
    delete(layout.buildDirectory)
}
