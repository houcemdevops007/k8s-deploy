import jenkins.model.*
import hudson.security.*
import com.michelin.cio.hudson.plugins.rolestrategy.RoleBasedAuthorizationStrategy
import com.michelin.cio.hudson.plugins.rolestrategy.Role
import com.michelin.cio.hudson.plugins.rolestrategy.PermissionEntry
import com.synopsys.arc.jenkins.plugins.rolestrategy.RoleType
import com.cloudbees.hudson.plugins.folder.*

def instance = Jenkins.get()

println("=== CONFIGURING JENKINS MULTI-TENANCY ===")

// 1. Security Realm
def hudsonRealm = new HudsonPrivateSecurityRealm(false, false, null)
instance.setSecurityRealm(hudsonRealm)

def adminUser = hudsonRealm.getUser("admin")
if (adminUser == null || hudsonRealm.allUsers.find { it.id == "admin" } == null) {
    hudsonRealm.createAccount("admin", "admin")
} else {
    adminUser.addProperty(HudsonPrivateSecurityRealm.Details.fromPlainPassword("admin"))
}

(1..20).each { i ->
    def uname = "efiadmin" + i
    def pword = "efiadmin" + i
    def user = hudsonRealm.getUser(uname)
    if (user == null || hudsonRealm.allUsers.find { it.id == uname } == null) {
        hudsonRealm.createAccount(uname, pword)
    } else {
        user.addProperty(HudsonPrivateSecurityRealm.Details.fromPlainPassword(pword))
    }
}

def getPerm = { id ->
    def p = Permission.fromId(id)
    if (p == null) println("WARNING: Null permission for ID: " + id)
    return p
}

RoleBasedAuthorizationStrategy rba = new RoleBasedAuthorizationStrategy()

// 2. Admin Global Role (FULL_CONTROL)
Set<Permission> adminPerms = new HashSet<>()
adminPerms.add(Permission.FULL_CONTROL)
Role adminRole = new Role("admin", adminPerms)
rba.addRole(RoleType.Global, adminRole)
rba.assignRole(RoleType.Global, adminRole, PermissionEntry.user("admin"))

// 3. Candidate Global Role (FULL_CONTROL allows access to Plugins, Tools, Nodes & Credentials management UI)
Set<Permission> candidateGlobalPerms = new HashSet<>()
candidateGlobalPerms.add(Permission.FULL_CONTROL)
Role candidateGlobalRole = new Role("candidate-global", candidateGlobalPerms)
rba.addRole(RoleType.Global, candidateGlobalRole)

(1..20).each { i ->
    def uname = "efiadmin" + i
    rba.assignRole(RoleType.Global, candidateGlobalRole, PermissionEntry.user(uname))
}

// 4. Item Roles per candidate (STRICT REGEX ^efiadminN($|[/-].*) guarantees folder isolation)
Set<Permission> itemPerms = new HashSet<>()
[
    "hudson.model.Item.Build",
    "hudson.model.Item.Cancel",
    "hudson.model.Item.Configure",
    "hudson.model.Item.Create",
    "hudson.model.Item.Delete",
    "hudson.model.Item.Discover",
    "hudson.model.Item.ExtendedRead",
    "hudson.model.Item.Move",
    "hudson.model.Item.Read",
    "hudson.model.Item.WipeOut",
    "hudson.model.Item.Workspace",
    "hudson.model.Run.Artifacts",
    "hudson.model.Run.Delete",
    "hudson.model.Run.Replay",
    "hudson.model.Run.Update"
].each { id ->
    def p = getPerm(id)
    if (p != null) itemPerms.add(p)
}

(1..20).each { i ->
    def uname = "efiadmin" + i
    def roleName = "role-" + uname
    def pattern = "^" + uname + "(\$|[/-].*)"
    Role candidateItemRole = new Role(roleName, pattern, itemPerms)
    rba.addRole(RoleType.Project, candidateItemRole)
    rba.assignRole(RoleType.Project, candidateItemRole, PermissionEntry.user(uname))
}

instance.setAuthorizationStrategy(rba)

// 5. Create top level folders efiadmin1 .. efiadmin20
(1..20).each { i ->
    def folderName = "efiadmin" + i
    if (instance.getItem(folderName) == null) {
        instance.createProject(Folder.class, folderName)
        println("Created folder: " + folderName)
    }
}

instance.save()
println("=== JENKINS MULTI-TENANCY CONFIGURATION SUCCESSFUL! ===")
