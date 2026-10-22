allprojects {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Algunos plugins (p.ej. whisper_ggml) declaran un compileSdk antiguo que choca
// con dependencias que exigen 35+ (ffmpeg_kit). Tras evaluar todos los módulos,
// forzamos compileSdk 36 en los módulos Android de los plugins.
gradle.projectsEvaluated {
    subprojects {
        extensions.findByName("android")?.let { ext ->
            try {
                val android = ext as com.android.build.gradle.BaseExtension
                android.compileSdkVersion(36)
                // Plugins antiguos (p.ej. vosk_flutter_2) no declaran `namespace`,
                // obligatorio en AGP 8. Si falta, lo tomamos del `group` del módulo
                // (que coincide con el package de su AndroidManifest).
                if (android.namespace == null) {
                    android.namespace = project.group.toString()
                }
            } catch (_: Exception) {
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
