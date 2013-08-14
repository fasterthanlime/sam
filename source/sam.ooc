
import structs/[ArrayList, List, HashMap]
import io/[File, FileReader]
import os/[Process, ShellUtils, Env, Pipe, PipeReader, Terminal]
import text/StringTokenizer

main: func (args: ArrayList<String>) {
    s := Sam new()
    s parseArgs(args)
}

Sam: class {

    home: File
    VERSION := "0.3.1"

    parseArgs: func (args: ArrayList<String>) {
        execFile := File new(args[0])

        try {
            execFile2 := ShellUtils findExecutable(execFile name, true)
            home = execFile2 getAbsoluteFile() parent
        } catch (e: Exception) {
            home = execFile getAbsoluteFile() parent
        }

        if (args size <= 1) {
            usage()
            exit(1)
        }

        command := args[1]

        try {
            runCommand(command, args)
        } catch (e: Exception) {
            log("We've had errors: %s", e message)
        }
    }

    runCommand: func (command: String, args: ArrayList<String>) {
        match (command) {
            case "update" =>
                update()
            case "get" =>
                doSelf := !(args contains?("--no-self"))
                get(getUseFile(args), doSelf)
            case "clone" =>
                withDeps := !(args contains?("--no-deps"))
                clone(getRepoName(args), withDeps)
            case "status" =>
                status(getUseFile(args))
            case "promote" =>
                promote(getUseFile(args))
            case "test" =>
                test(args)
            case =>
                log("Unknown command: %s", command)
                usage()
                exit(1)
        }
    }

    usage: func {
        log("sam version %s", VERSION)
        log(" ")
        log("Usage: sam [update|get|status|promote|clone|test]")
        log(" ")
        log("Commands")
        log("  * update: update sam's grimoir of formulas")
        log("  * get [--no-self] [USEFILE]: clone and/or pull all dependencies (optionally excluding the current repository)")
        log("  * status [USEFILE]: display short git status of all dependencies")
        log("  * promote [USEFILE]: replace read-only github url with a read-write one for given use file")
        log("  * clone [--no-deps] [REPONAME]: clone a repository by its formula name")
        log("  * test [--test=FILE.ooc] [USEFILE]: run all tests or a single specified test")
        log(" ")
        log("Note: All USEFILE arguments are optional. By default, the")
        log("first .use file of the current directory is used")
        log(" ")
        log("Copyleft 2013 Amos Wenger aka @nddrylliog")
    }

    update: func {
        log("Pulling repository %s", home path)
        GitRepo new(home path) pull()
        log("Recompiling sam")
        rock := Rock new(home path)
        rock clean()
        rock compile()
    }

    get: func (useFile: UseFile, doSelf: Bool) {
        if (doSelf) {
            log("[%s]", useFile name)
            useFile repo() pull()
        }

        if (useFile deps empty?()) {
            log("%s has no dependencies! Our work here is done.", useFile name)
            return
        }

        pp := ActionPool new(this, ActionType GET)
        for (dep in useFile deps) {
            pp add(useFile name, dep)
        }
        pp run()
    }

    clone: func (name: String, withDeps: Bool) {
        f := Formula new(this, name)
        url := f origin
        repo := GitRepo new(File new(GitRepo oocLibs(), f name) path, url)
        
        if(repo exists?()) {
            log("[%s:%s]", name, repo getBranch())
            log("Repository %s exists already. Pulling...", repo dir)
            repo pull()
        } else {
            log("[%s]", name)
            repo clone()
            log("Cloned %s into %s", url, repo dir)
        }

        if (withDeps) {
            get(UseFile new("%s/%s.use" format(repo dir, name)), false)
        }
    }

    status: func (useFile: UseFile) {
        repo := useFile repo()
        log("[%s:%s]", useFile name, repo getBranch())
        repo status()

        if (useFile deps empty?()) {
            log("%s has no dependencies. Our work here is done.", useFile name)
            return
        }

        pp := ActionPool new(this, ActionType STATUS)
        for (dep in useFile deps) {
            pp add(useFile name, dep)
        }
        pp run()
    }

    test: func (args: List<String>) {
        useFile := getUseFile(args)
        repo := useFile repo()

        repoDir := File new(repo dir)
        testDir := File new(repoDir, "test")
        if (!testDir exists?()) {
            log("No 'test' directory for %s. Our work here is done!", useFile name)
            return
        }

        log("Running tests for %s:%s", useFile name, repo getBranch())
        cacheDir := File new(repoDir, ".sam-cache")

        testDir walk(|f|
            if (f getName() toLower() endsWith?(".ooc")) {
                cacheDir mkdirs()
                doTest(cacheDir, testDir, f getAbsoluteFile())
            }

            true
        )
        println()
    }

    doTest: func (cacheDir: File, testDir: File, oocFile: File) {
        testName := oocFile rebase(testDir) path
        log(" > %s" format(testName))

        File new(cacheDir, "test.use") write(
            "SourcePath: %s\n" format(oocFile parent path) +
            "Main: %s\n" format(oocFile name)
        )

        rock := Rock new(cacheDir path)
        rock quiet = true
        rock fatal = false
        (output, exitCode) := rock compile(["-o=test", "-q"] as ArrayList<String>)

        if (exitCode == 0) {
            exec := AnyExecutable new(cacheDir path, File new(cacheDir, "test"))
            exec quiet = true
            exec fatal = false
            (execOutput, execExitCode) := exec run()
            if (execExitCode == 0) {
                "[ OK ]" println()
            } else {
                "[FAIL]" println()
            }
        } else {
            "[ERR']" println()

            Terminal setFgColor(Color red)
            output println()
            Terminal reset()
        }

        system("rm -rf %s" format(cacheDir path))
    }

    promote: func (useFile: UseFile) {
        log("Promoting %s", useFile name)

        useFile repo() promote()
    }

    filterArgs: func (givenArgs: List<String>) -> List<String> {
        givenArgs filter(|arg| !arg startsWith?("--"))
    }

    getUseFile: func (givenArgs: List<String>) -> UseFile {
        args := filterArgs(givenArgs)
        if (args size > 2) {
            UseFile new(args[2])
        } else {
            firstUse := firstUseFilePath()
            if (firstUse) {
                UseFile new(firstUse)
            } else {
                log("No .use file specified and none found in current directory. Sayonara!")
                exit(1)
            }
        }
    }

    getRepoName: func (givenArgs: List<String>) -> String {
        args := filterArgs(givenArgs)
        if (args size > 2) {
            return args[2]
        }

        log("No repo name specified. Adios!")
        exit(1)
    }

    firstUseFilePath: func -> String {
        children := File new(".") getChildren()
        for (c in children) {
            if (c name endsWith?(".use")) {
                return c path
            }
        }
        null
    }

    log: func (s: String) {
        "%s" printfln(s)
    }

    log: func ~var (s: String, args: ...) {
        s printfln(args)
    }
    
}

UseFile: class {

    path: String
    name: String
    dir: String

    props := HashMap<String, String> new()
    deps := ArrayList<String> new()

    init: func (=path) {
        f := File new(path)
        name = f name[0..-5]
        dir = File new(path) getAbsoluteFile() parent path

        parse()
    }

    find: static func (name: String) -> This {
        dirs := File new(GitRepo oocLibs()) getChildren() filter(|f| f dir?())
        fileName := "%s.use" format(name)

        for (dir in dirs) {
            for (child in dir getChildren()) {
                if (child name == fileName) {
                    return This new(child path)
                }
            }
        }

        null
    }

    parse: func {
        PropReader new(path, props)

        // parse deps
        requires := props get("Requires")
        if (requires) {
            deps addAll(requires split(',', false) map (|dep| dep trim(" \t")))
        }
    }

    repo: func -> GitRepo {
        GitRepo new(dir)
    }

}

PropReader: class {

    init: func (path: String, props: HashMap<String, String>) {
        fr := FileReader new(path)

        while (fr hasNext?()) {
            line := fr readLine() trim("\t ")

            if (line startsWith?('#') || line empty?()) {
                continue
            }

            tokens := line split(':', false)
            if (tokens size <= 1) {
                continue
            }

            key := tokens removeAt(0)
            value := tokens join(":")
            props put(key trim("\t "), value trim("\t "))
        }

        fr close()
    }

}

GitException: class extends Exception {
    
    init: super func

}

CLITool: class {

    dir: String
    quiet := false
    fatal := true

    init: func (=dir) {
        assert (dir != null)
    }
    
    printOutput: func (output: String) {
        formatted := output split('\n', false) \
                     map(|line| line trim("\t ")) \
                     filter(|line| !line empty?()) \
                     map(|line| " > " + line) \
                     join("\n") \
                     trim("\n")
        if (!formatted empty?()) {
            formatted println()
        }
    }

    launch: func (p: Process, message: String) -> (String, Int) {
        p stdErr = Pipe new()
        (output, exitCode) := p getOutput()

        if (!quiet) {
            printOutput(output)
        }
        
        if (fatal && exitCode != 0) {
            GitException new(message) throw()
        }

        (output, exitCode)
    }
}

GitRepo: class extends CLITool {

    GIT_PATH: static String = null
    OOC_LIBS: static String = null

    url: String

    init: func (.dir, =url) {
        super(dir)
    }

    init: func ~noUrl (.dir) {
        init(dir, "")
    }

    pull: func {
        p := Process new([gitPath(), "pull"])
        p setCwd(dir)
        (output, exitCode) := p getOutput()
        printOutput(output)
        
        if (exitCode != 0) {
            GitException new("Failed to pull repository in %s" format(dir)) throw()
        }
    }

    clone: func {
        p := Process new([gitPath(), "clone", url, dir])
        (output, exitCode) := p getOutput()
        printOutput(output)
        
        if (exitCode != 0) {
            GitException new("Failed to clone repository %s into %s" format(url, dir)) throw()
        }
    }

    getBranch: func -> String {
        p := Process new([gitPath(), "rev-parse", "--abbrev-ref", "HEAD"])
        p setCwd(dir)
        (output, exitCode) := p getOutput()
        
        if (exitCode != 0) {
            GitException new("Failed to get status of repository %s" format(dir)) throw()
        }
        return output trim(" \t\r\n")
    }

    status: func {
        p := Process new([gitPath(), "status", "--short"])
        p setCwd(dir)
        (output, exitCode) := p getOutput()
        printOutput(output)
        
        if (exitCode != 0) {
            GitException new("Failed to get status of repository %s" format(dir)) throw()
        }
    }

    promote: func {
        gitDir := File new(dir, ".git")
        if (!gitDir exists?()) {
            GitException new("%s is not a git repository" format(dir)) throw()
        }

        configFile := File new(gitDir, "config")
        if (!configFile exists?()) {
            GitException new("%s doesn't have a .git/config file" format(dir)) throw()
        }

        fr := FileReader new(configFile)

        foundOrigin := false

        while (fr hasNext?()) {
            line := fr readLine() trim("\t ")
            if (line startsWith?("[remote \"origin\"]")) {
                foundOrigin = true
                break
            }
        }

        if (!foundOrigin) {
            GitException new("No 'origin' remote in repo %s" format(dir)) throw()
        }

        url: String

        while (fr hasNext?()) {
            line := fr readLine() trim("\t ")
            if (line startsWith?("url = ")) {
                url = line split('=', false)[1] trim("\t ")
                break
            }
        }

        "Found url: %s" format(url) println()

        if (url startsWith?("git@github.com")) {
            "Already read-write! Maybe you don't have push access?" println()
            return
        }

        sshUrl: String

        // To understand the next part, read:
        // https://help.github.com/articles/which-remote-url-should-i-use

        // https urls are smart, they'll be either read-only or read-write
        // depending on your permissions. But they require special setup
        // so that you don't have to enter your username/password everytime.
        HTTPS_PREFIX := "https://github.com/"
        if (url startsWith?(HTTPS_PREFIX)) {
            repoName := url[HTTPS_PREFIX size..-1]
            if (repoName endsWith?(".git")) {
                // URLs with or without '.git' are valid, but we want it without
                repoName = repoName[0..-5]
            }

            // create an SSH url
            sshUrl = "git@github.com:%s.git" format(repoName)
        }

        // git urls are always read-only
        GIT_PREFIX := "git://"
        if (url startsWith?(GIT_PREFIX)) {
            repoName := url[GIT_PREFIX size..-1]
            if (repoName endsWith?(".git")) {
                // URLs with or without '.git' are valid, but we want it without
                repoName = repoName[0..-5]
            }

            // create an ssh url
            sshUrl = "git@github.com:%s.git" format(repoName)
        }

        fr close()
        content := configFile read() replaceAll(url, sshUrl)
        "Will replace your .git/config file with this: " println()
        "====================================" println()
        content println()
        "====================================" println()

        "Are you okay with that? [y/N]" println()
        inputReader := FileReader new(stdin)
        answer := inputReader readLine()
        inputReader close()

        if (answer startsWith?("y")) {
            configFile write(content)
            "Done!" println()
        } else {
            "Not doing anything." println()
        }
    }

    exists?: func -> Bool {
        File new(dir) exists?()
    }

    gitPath: static func -> String {
        if (!GIT_PATH) {
            GIT_PATH = ShellUtils findExecutable("git", true) path
        }
        GIT_PATH
    }

    oocLibs: static func -> String {
        if (!OOC_LIBS) {
            OOC_LIBS = Env get("OOC_LIBS")
            if (!OOC_LIBS) {
                GitException new("$OOC_LIBS environment variable not defined! I'm outta here.") throw()
            }
            if (!(File new(OOC_LIBS) exists?())) {
                GitException new("$OOC_LIBS is set to %s, which doesn't exist. Ciao!" format(OOC_LIBS)) throw()
            }
        }
        OOC_LIBS
    }

    dirName: static func (gitUrl: String) -> String {
        if (!gitUrl endsWith?(".git")) {
            GitException new("Invalid git url: %s" format(gitUrl)) throw()
        }

        // trim '.git', get part before '/'
        dirName := gitUrl[0..-5] split('/') last()
        dirName
    }

    log: func (s: String) {
        "%s" printfln(s)
    }

}

SamException: class extends Exception {
    
    init: super func

}

ActionType: enum {
    GET
    STATUS
}

ActionTask: class {

    sam: Sam
    parent, name: String

    init: func (=sam, =parent, =name) {

    }

    process: func (pool: ActionPool) {
        f := Formula new(sam, name)
        url := f origin

        dirName := GitRepo dirName(url)
        repo := GitRepo new(File new(GitRepo oocLibs(), dirName) path, url)

        sam log("[%s:%s] (<= %s)", name, repo getBranch(), parent)

        doGet := func {
            if (repo exists?()) {
                repo pull()
            } else {
                repo clone()
            }

            useFile := UseFile find(name)
            if (!useFile) {
                SamException new("use file for %s not found after cloning/pulling" format(name)) throw()
            }

            for (dep in useFile deps) {
                pool add(name, dep)
            }
        }

        doStatus := func {
            if (repo exists?()) {
                repo status()
            } else {
                sam log("Repository %s doesn't exist!", repo dir)
                return
            }

            useFile := UseFile find(name)
            if (!useFile) {
                SamException new("use file for %s not found after cloning/pulling" format(name)) throw()
            }

            for (dep in useFile deps) {
                pool add(name, dep)
            }
        }

        match (pool actionType) {
            case ActionType GET =>
                doGet()
            case ActionType STATUS =>
                doStatus()
        }
    }

}

ActionPool: class {

    sam: Sam
    queued := HashMap<String, ActionTask> new()
    doing := ArrayList<ActionTask> new()
    actionType: ActionType

    init: func (=sam, =actionType) {
    }

    add: func (parent, name: String) {
        if (queued contains?(name)) {
            return
        }

        task := ActionTask new(sam, parent, name)
        queued put(name, task)
        doing add(task)
    }

    run: func {
        while (!doing empty?()) {
            current := doing removeAt(0)
            current process(this)
        }
    }

}

Formula: class {

    sam: Sam
    name, path: String

    origin: String

    props := HashMap<String, String> new()

    init: func (=sam, =name) {
        file := File new(File new(sam home, "library"), "%s.yml" format(name))
        path = file path

        if (!file exists?()) {
            SamException new("Unknown formula: %s (tried %s)" format(name, path)) throw()
        }

        parse()
    }

    parse: func {
        PropReader new(path, props)

        if (!props contains?("Origin")) {
            SamException new("Malformed formula (doesn't contain Origin): %s" format(path)) throw()
        }

        origin = props get("Origin")
    }

}

Rock: class extends CLITool {

    ROCK_PATH: static String = null

    init: func (=dir) {
        assert (dir != null)
    }

    clean: func {
        p := Process new([rockPath(), "-x"])
        p setCwd(dir)

        launch(p, "Failed to run rock -x in %s" format(dir))
    }

    compile: func (args: List<String> = null) -> (String, Int) {
        rockArgs := [rockPath()] as ArrayList
        if (args) {
            rockArgs addAll(args)
        }
        
        p := Process new(rockArgs)
        p setCwd(dir)
        message := "Failed to use rock to compile in %s" format(dir)
        (output, exitCode) := launch(p, message)
        (output, exitCode)
    }

    rockPath: static func -> String {
        if (!ROCK_PATH) {
            ROCK_PATH = ShellUtils findExecutable("rock", true) path
        }
        ROCK_PATH
    }

}

AnyExecutable: class extends CLITool {

    file: File
    
    init: func (.dir, =file) {
        super(dir)

        if (!file exists?()) {
            GitException new("Tried to launch nonexistent executable %s" format(file path)) throw()
        }
    }

    run: func -> (String, Int) {
        p := Process new([file path])
        p setCwd(dir)

        message := "Failed to launch %s in %s" format(file name, dir)
        (output, exitCode) := launch(p, message)
        (output, exitCode)
    }

}

// hackety hack shamefully hidden here.
system: extern func (command: CString)

