import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.util.Base64
import org.gradle.api.tasks.Exec

plugins {
    id("maven-publish")
    id("signing")
}

group = "com.helpchoice.hal"
version = "1.0.0"

val archiveName = "HALDiSh"
val scriptsDir = file("src/main/scripts")
val buildArchiveDir = file("$buildDir/archive")
val selfExtractingArchive = file("$buildDir/distributions/$archiveName-$version.sh")

tasks.register("prepareArchive") {
    description = "Prepare scripts for archiving"

    doLast {
        delete(buildArchiveDir)
        mkdir(buildArchiveDir)

        // Copy all scripts from src/main/scripts
        copy {
            from(scriptsDir)
            into(buildArchiveDir)
        }

        // Ensure init.sh is present
        val initScript = file("$buildArchiveDir/init.sh")
        if (!initScript.exists()) {
            throw GradleException("init.sh must exist in src/main/scripts")
        }

        // Make all scripts executable
        fileTree(buildArchiveDir).forEach { file ->
            file.setExecutable(true)
        }
    }
}

tasks.register<Exec>("createTarball") {
    dependsOn("prepareArchive")
    description = "Create tarball of scripts"

    workingDir = buildArchiveDir.parentFile
    commandLine("tar", "czf", "scripts.tar.gz", "-C", buildArchiveDir.name, ".")

    doLast {
        val tarball = file("$buildDir/archive.tar.gz")
        file("${buildArchiveDir.parent}/scripts.tar.gz").renameTo(tarball)
    }
}

tasks.register("buildSelfExtractingArchive") {
    dependsOn("createTarball")
    description = "Build self-extracting archive that auto-executes init.sh"

    doLast {
        val tarball = file("$buildDir/archive.tar.gz")
        val outputDir = selfExtractingArchive.parentFile
        mkdir(outputDir)

        // Create the self-extracting script
        selfExtractingArchive.writeText(
            """#!/bin/bash
# Self-extracting archive created by Gradle
# This archive will automatically extract and execute init.sh

set -e

EXTRACT_DIR=${'$'}(mktemp -d)
ARCHIVE_START_LINE=${'$'}(awk '/^__ARCHIVE_BELOW__${'$'}/ { print NR + 1; exit 0; }' "${'$'}0")

echo "Extracting to ${'$'}EXTRACT_DIR..."
tail -n +${'$'}ARCHIVE_START_LINE "${'$'}0" | tar xz -C "${'$'}EXTRACT_DIR"

cp ${'$'}EXTRACT_DIR/* .

echo ""
echo "Executing init.sh..."
if [ -f init.sh ]; then
    chmod +x init.sh
    ./init.sh "${'$'}@"
    EXIT_CODE=${'$'}?
else
    echo "Error: init.sh not found in archive"
    EXIT_CODE=1
fi

# Cleanup
rm -rf "${'$'}EXTRACT_DIR"

exit ${'$'}EXIT_CODE

__ARCHIVE_BELOW__
"""
        )

        // Append the tarball
        tarball.inputStream().use { input ->
            selfExtractingArchive.appendBytes(input.readBytes())
        }

        // Make executable
        selfExtractingArchive.setExecutable(true)

        println("Self-extracting archive created: ${selfExtractingArchive.absolutePath}")
    }
}

val scriptDir = layout.projectDirectory.dir("src/tests/scripts")

tasks.register<Exec>("testAdocSpec") {
    group = "verification"
    description = "Runs the adocSpec.sh test script"
    dependsOn("buildArchive")

    workingDir = scriptDir.asFile

    doFirst {
        commandLine("/bin/sh", scriptDir.file("adocSpec.sh").asFile.absolutePath)
    }
}

tasks.register<Exec>("testGETSpec") {
    group = "verification"
    description = "Runs the GETSpec.sh test script"
    dependsOn("buildArchive")

    workingDir = scriptDir.asFile
    commandLine("/bin/sh", scriptDir.file("GETSpec.sh").asFile.absolutePath)
}

tasks.register<Exec>("testRenameSpec") {
    group = "verification"
    description = "Runs the renameSpec.sh test script"
    dependsOn("buildArchive")

    workingDir = scriptDir.asFile
    commandLine("/bin/sh", scriptDir.file("renameSpec.sh").asFile.absolutePath)
}

tasks.register<Exec>("testUriTEnginSpec") {
    group = "verification"
    description = "Runs the uritenginSpec.sh test script"
    dependsOn("buildArchive")

    workingDir = scriptDir.asFile
    commandLine("/bin/sh", scriptDir.file("uritenginSpec.sh").asFile.absolutePath)
}

tasks.named("check") {
    dependsOn("testAdocSpec", "testGETSpec", "testRenameSpec", "testUriTEnginSpec")
}

tasks.named("assemble") {
    dependsOn("buildSelfExtractingArchive")
}

tasks.register("buildArchive") {
    dependsOn("buildSelfExtractingArchive")
    group = "build"
    description = "Build the self-extracting archive"
}

tasks.register<Jar>("sourcesJar") {
    archiveClassifier.set("sources")
    from(scriptsDir)
}

tasks.register<Jar>("javadocJar") {
    archiveClassifier.set("javadoc")
    from(file("README.md"))
}

publishing {
    publications {
        create<MavenPublication>("mavenJava") {
            artifactId = archiveName

            artifact(selfExtractingArchive) {
                extension = "sh"
            }

//            artifact(tasks["sourcesJar"])
//            artifact(tasks["javadocJar"])

            pom {
                name.set("HALDiSh")
                description.set(
                    """A self-extracting archive that
                     contains a bash scripts to help discover the HAL remote server API."""
                )
                url.set("https://github.com/C06A/HALDiSh")

                licenses {
                    license {
                        name.set("The Apache License, Version 2.0")
                        url.set("http://www.apache.org/licenses/LICENSE-2.0.txt")
                    }
                }

                developers {
                    developer {
                        id.set("C06A")
                        name.set("C.A.B.")
                        email.set("maven@helpchoice.com")
                    }
                }

                scm {
                    connection.set("scm:git:git://github.com/C06A/HALDiSh.git")
                    developerConnection.set("scm:git:ssh://github.com/C06A/HALDiSh.git")
                    url.set("https://github.com/C06A/HALDiSh")
                }
            }
        }
    }

    configure<SigningExtension> {
        val keyFilePath = findProperty("signingKeyFile") as String?
        val password = (findProperty("signingPassword") as String?) ?: ""

        if (keyFilePath.isNullOrBlank()) {
            error("signingKeyFile is not set (define it in ~/.gradle/gradle.properties)")
        }

        val signingKey = file(keyFilePath).readText()

        useInMemoryPgpKeys(signingKey, password)
        sign(publishing.publications["mavenJava"])
    }

    repositories {
        maven {
            name = "OSSRH"
//            val releasesRepoUrl = uri("https://s01.oss.sonatype.org/service/local/staging/deploy/maven2/")
            val releasesRepoUrl = uri(
                "https://ossrh-staging-api.central.sonatype.com/service/local/staging/deploy/maven2/"
            )
//            val snapshotsRepoUrl = uri("https://s01.oss.sonatype.org/content/repositories/snapshots/")
            val snapshotsRepoUrl = uri(
                "https://central.sonatype.com/repository/maven-snapshots/"
            )

            url = if (version.toString().endsWith("SNAPSHOT")) snapshotsRepoUrl else releasesRepoUrl

            credentials {
                username = findProperty("mavenCentralUsername") as String? ?: System.getenv("OSSRH_USERNAME")
                password = findProperty("mavenCentralPassword") as String? ?: System.getenv("OSSRH_PASSWORD")
            }
        }
    }
}

tasks.named("publishMavenJavaPublicationToOSSRHRepository") {
    dependsOn("assemble")
}

tasks.register("publishToMavenCentral") {
    group = "publishing"
    description = "Publishes all Maven publications to Maven Central via OSSRH Staging API + Portal."

    // 1) First do the normal Gradle publish (to ossrh-staging-api)
    dependsOn("publish")

    doLast {
        // 2) Then notify the OSSRH Staging API to push to the Portal
        val username = findProperty("mavenCentralUsername") as String?
            ?: error("mavenCentralUsername is not set (add to ~/.gradle/gradle.properties)")
        val password = findProperty("mavenCentralPassword") as String?
            ?: error("mavenCentralPassword is not set (add to ~/.gradle/gradle.properties)")
        val namespace = findProperty("mavenCentralNamespace") as String?
            ?: error("mavenCentralNamespace is not set (add to ~/.gradle/gradle.properties)")

        val token = Base64.getEncoder().encodeToString("$username:$password".toByteArray())

        val client = HttpClient.newHttpClient()
        val url =
            "https://ossrh-staging-api.central.sonatype.com/manual/upload/defaultRepository/$namespace?publishing_type=user_managed"

        val request = HttpRequest.newBuilder()
            .uri(URI.create(url))
            .header("Authorization", "Bearer $token")
            .POST(HttpRequest.BodyPublishers.noBody())
            .build()

        val response = client.send(request, HttpResponse.BodyHandlers.ofString())

        if (response.statusCode() !in 200..299) {
            error(
                "Failed to trigger upload to Central Portal.\n" +
                        "HTTP ${response.statusCode()}:\n${response.body()}"
            )
        } else {
            println("Successfully triggered upload to Central Portal (HTTP ${response.statusCode()})")
        }
    }
}
