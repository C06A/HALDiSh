plugins {
    id("maven-publish")
    id("signing")
}

group = "com.helpchoice.hal"
version = "1.0.0-SHAPSHOT"

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
        selfExtractingArchive.writeText("""#!/bin/bash
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
""")
        
        // Append the tarball
        tarball.inputStream().use { input ->
            selfExtractingArchive.appendBytes(input.readBytes())
        }
        
        // Make executable
        selfExtractingArchive.setExecutable(true)
        
        println("Self-extracting archive created: ${selfExtractingArchive.absolutePath}")
    }
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
            
            artifact(tasks["sourcesJar"])
            artifact(tasks["javadocJar"])
            
            pom {
                name.set("Self-Extracting Scripts Archive")
                description.set("A self-extracting archive that automatically executes init.sh upon extraction")
                url.set("https://github.com/yourusername/your-repo")
                
                licenses {
                    license {
                        name.set("The Apache License, Version 2.0")
                        url.set("http://www.apache.org/licenses/LICENSE-2.0.txt")
                    }
                }
                
                developers {
                    developer {
                        id.set("yourId")
                        name.set("Your Name")
                        email.set("your.email@example.com")
                    }
                }
                
                scm {
                    connection.set("scm:git:git://github.com/yourusername/your-repo.git")
                    developerConnection.set("scm:git:ssh://github.com/yourusername/your-repo.git")
                    url.set("https://github.com/yourusername/your-repo")
                }
            }
        }
    }
    
    repositories {
        maven {
            name = "OSSRH"
            val releasesRepoUrl = uri("https://s01.oss.sonatype.org/service/local/staging/deploy/maven2/")
            val snapshotsRepoUrl = uri("https://s01.oss.sonatype.org/content/repositories/snapshots/")
            url = if (version.toString().endsWith("SNAPSHOT")) snapshotsRepoUrl else releasesRepoUrl
            
            credentials {
                username = findProperty("ossrhUsername") as String? ?: System.getenv("OSSRH_USERNAME")
                password = findProperty("ossrhPassword") as String? ?: System.getenv("OSSRH_PASSWORD")
            }
        }
    }
}

signing {
    sign(publishing.publications["mavenJava"])
}

tasks.named("publishMavenJavaPublicationToOSSRHRepository") {
    dependsOn("assemble")
}
