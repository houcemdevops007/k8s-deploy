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

// 2. Admin Global Role (FULL ADMINISTER for admin user ONLY)
Set<Permission> adminPerms = new HashSet<>()
adminPerms.add(getPerm("hudson.model.Hudson.Administer"))
Role adminRole = new Role("admin", adminPerms)
rba.addRole(RoleType.Global, adminRole)
rba.assignRole(RoleType.Global, adminRole, PermissionEntry.user("admin"))

// 3. Candidate Global Role (Fine-grained perms: Read, Manage, SystemRead, UploadPlugins, ConfigureUpdateCenter, Computer.*, CredentialsProvider.*, View.*)
Set<Permission> candidateGlobalPerms = new HashSet<>()
[
    "hudson.model.Hudson.Read",
    "hudson.model.Hudson.Manage",
    "hudson.model.Hudson.SystemRead",
    "hudson.model.Hudson.UploadPlugins",
    "hudson.model.Hudson.ConfigureUpdateCenter",
    "hudson.model.Computer.Create",
    "hudson.model.Computer.Configure",
    "hudson.model.Computer.Connect",
    "hudson.model.Computer.Delete",
    "hudson.model.Computer.Disconnect",
    "hudson.model.Computer.ExtendedRead",
    "hudson.model.Computer.Provision",
    "hudson.model.Computer.Build",
    "com.cloudbees.plugins.credentials.CredentialsProvider.Create",
    "com.cloudbees.plugins.credentials.CredentialsProvider.Delete",
    "com.cloudbees.plugins.credentials.CredentialsProvider.ManageDomains",
    "com.cloudbees.plugins.credentials.CredentialsProvider.Update",
    "com.cloudbees.plugins.credentials.CredentialsProvider.UseItem",
    "com.cloudbees.plugins.credentials.CredentialsProvider.UseOwn",
    "com.cloudbees.plugins.credentials.CredentialsProvider.View",
    "hudson.model.View.Create",
    "hudson.model.View.Configure",
    "hudson.model.View.Delete",
    "hudson.model.View.Read"
].each { id ->
    def p = getPerm(id)
    if (p != null) candidateGlobalPerms.add(p)
}

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
    "hudson.model.Run.Update",
    "com.cloudbees.plugins.credentials.CredentialsProvider.Create",
    "com.cloudbees.plugins.credentials.CredentialsProvider.Delete",
    "com.cloudbees.plugins.credentials.CredentialsProvider.ManageDomains",
    "com.cloudbees.plugins.credentials.CredentialsProvider.Update",
    "com.cloudbees.plugins.credentials.CredentialsProvider.UseItem",
    "com.cloudbees.plugins.credentials.CredentialsProvider.UseOwn",
    "com.cloudbees.plugins.credentials.CredentialsProvider.View"
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
    }
}

instance.save()
println("=== JENKINS MULTI-TENANCY CONFIGURATION SUCCESSFUL! ===")
