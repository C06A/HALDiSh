import java.util.Base64

plugins {
    `maven-publish`
    signing
}

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

// ─── publish ──────────────────────────────────────────────────────────────────

/**
 * Publishes the .run archive to Sonatype OSSRH (releases or snapshots).
 *
 * Required credentials — supply via ~/.gradle/gradle.properties or env vars:
 *   mavenCentralUsername  / MAVEN_CENTRAL_USERNAME
 *   mavenCentralPassword  / MAVEN_CENTRAL_PASSWORD
 *   mavenCentralNamespace / MAVEN_CENTRAL_NAMESPACE  — Maven groupId (e.g. com.haldish)
 *
 * Required signing keys (in-memory PGP):
 *   signingKeyFile  / SIGNING_KEY_FILE  — path to ASCII-armoured private key file
 *   signingPassword / SIGNING_PASSWORD  — key passphrase
 */
publishing {
    publications {
        create<MavenPublication>("runArchive") {
            groupId    = providers.gradleProperty("mavenCentralNamespace")
                .orElse(providers.environmentVariable("MAVEN_CENTRAL_NAMESPACE"))
                .orElse(project.group.toString()).get()
            artifactId = rootProject.name.lowercase()

            artifact(distDir.resolve(archiveName)) {
                extension = "run"
                builtBy("assembleDist")
            }

            pom {
                name.set(rootProject.name)
                description.set("HAL JSON/YAML/XML interactive navigator and bash utility library")
                url.set("https://github.com/C06A/HALDiSh")

                licenses {
                    license {
                        name.set("MIT License")
                        url.set("https://opensource.org/licenses/MIT")
                    }
                }

                developers {
                    developer {
                        id.set("C06A")
                        name.set("C06A")
                        url.set("https://github.com/C06A")
                    }
                }

                scm {
                    connection.set("scm:git:https://github.com/C06A/HALDiSh.git")
                    developerConnection.set("scm:git:ssh://github.com/C06A/HALDiSh.git")
                    url.set("https://github.com/C06A/HALDiSh")
                }
            }
        }
    }

    repositories {
        maven {
            name = "sonatype"
            val releasesUrl  = uri("https://s01.oss.sonatype.org/service/local/staging/deploy/maven2/")
            val snapshotsUrl = uri("https://s01.oss.sonatype.org/content/repositories/snapshots/")
            url = if (version.toString().endsWith("SNAPSHOT")) snapshotsUrl else releasesUrl

            credentials {
                username = providers.gradleProperty("mavenCentralUsername")
                    .orElse(providers.environmentVariable("MAVEN_CENTRAL_USERNAME")).orNull
                password = providers.gradleProperty("mavenCentralPassword")
                    .orElse(providers.environmentVariable("MAVEN_CENTRAL_PASSWORD")).orNull
            }
        }
    }
}

signing {
    val signingKeyFile = providers.gradleProperty("signingKeyFile")
        .orElse(providers.environmentVariable("SIGNING_KEY_FILE")).orNull
    val signingPassword = providers.gradleProperty("signingPassword")
        .orElse(providers.environmentVariable("SIGNING_PASSWORD")).orNull
    if (signingKeyFile != null && signingPassword != null) {
        useInMemoryPgpKeys(file(signingKeyFile).readText(), signingPassword)
    }
    sign(publishing.publications["runArchive"])
}

tasks.named("publishRunArchivePublicationToSonatypeRepository") {
    dependsOn("assembleDist")
}

tasks.named("assemble") {
    dependsOn("assembleDist")
}

tasks.named("build") {
    dependsOn("assemble", "test")
}

tasks.named<Delete>("clean") {
    delete(layout.buildDirectory)
}
