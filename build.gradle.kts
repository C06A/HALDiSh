allprojects {
    group   = "com.helpchoice.hal"
    version = "2.0.0"
}

// Each subproject declares its own lifecycle tasks (clean, build, test, etc.)
// in its own build.gradle.kts file.

// ─── README conversion ────────────────────────────────────────────────────────

/**
 * Converts README.asciidoc → README.md using pandoc (GitHub Flavored Markdown).
 *
 * Requires pandoc to be installed:  https://pandoc.org/installing.html
 */
tasks.register<Exec>("convertReadme") {
    group       = "documentation"
    description = "Converts README.asciidoc to README.md via pandoc."

    inputs.file("README.asciidoc")
    outputs.file("README.md")

    commandLine(
        "pandoc", "README.asciidoc",
        "--from", "asciidoc",
        "--to",   "gfm",
        "--output", "README.md"
    )

    doFirst {
        val pandoc = ProcessBuilder("which", "pandoc")
            .redirectErrorStream(true).start()
        pandoc.waitFor()
        if (pandoc.exitValue() != 0) {
            throw GradleException(
                "pandoc not found — install it from https://pandoc.org/installing.html"
            )
        }
    }
}

// ─── Git hooks ────────────────────────────────────────────────────────────────

/**
 * Copies every file from .githooks/ into .git/hooks/ and marks it executable.
 * Run once after cloning:  ./gradlew installGitHooks
 *
 * The pre-commit hook enforces that README.md is never edited directly;
 * changes must go through README.asciidoc, from which README.md is generated
 * automatically at commit time.
 */
tasks.register("installGitHooks") {
    group       = "setup"
    description = "Installs shared git hooks from .githooks/ into .git/hooks/."

    val sourceDir = file(".githooks")
    val targetDir = file(".git/hooks")

    inputs.dir(sourceDir)

    doLast {
        sourceDir.listFiles()?.forEach { hook ->
            val target = targetDir.resolve(hook.name)
            hook.copyTo(target, overwrite = true)
            target.setExecutable(true)
            logger.lifecycle("Installed git hook: ${hook.name}")
        }
    }
}
