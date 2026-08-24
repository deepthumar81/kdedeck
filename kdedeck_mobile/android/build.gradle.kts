allprojects {
    repositories {
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

subprojects {
    plugins.withId("com.android.library") {
        val android = project.extensions.findByName("android") as? com.android.build.gradle.BaseExtension
        android?.ndkVersion = ""
    }
    plugins.withId("com.android.application") {
        val android = project.extensions.findByName("android") as? com.android.build.gradle.BaseExtension
        android?.ndkVersion = ""
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
