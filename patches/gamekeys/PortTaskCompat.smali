# Port Porting-Rom-AOSP: pengganti registerTaskStackListener untuk GameKeys tanpa kunci platform.
# registerTaskStackListener butuh MANAGE_ACTIVITY_TASKS (signature) -> SecurityException kalau
# GameKeys bukan platform_app. Fallback: thread yang tiap 700 ms membaca task teratas lewat
# ActivityTaskManager.getTasks(1, true) (izin REAL_GET_TASKS = privileged, ditambahkan ke manifest)
# dan memanggil listener.onTaskMovedToFront() hanya saat package berganti.
.class public final Lorg/lineageos/gamekeys/service/PortTaskCompat;
.super Ljava/lang/Object;
.implements Ljava/lang/Runnable;

.field private static sPoller:Ljava/lang/Thread;

.field private final atm:Landroid/app/ActivityTaskManager;

.field private final listener:Landroid/app/TaskStackListener;


.method private constructor <init>(Landroid/app/ActivityTaskManager;Landroid/app/TaskStackListener;)V
    .registers 3

    invoke-direct {p0}, Ljava/lang/Object;-><init>()V

    iput-object p1, p0, Lorg/lineageos/gamekeys/service/PortTaskCompat;->atm:Landroid/app/ActivityTaskManager;

    iput-object p2, p0, Lorg/lineageos/gamekeys/service/PortTaskCompat;->listener:Landroid/app/TaskStackListener;

    return-void
.end method

.method public static register(Landroid/app/ActivityTaskManager;Landroid/app/TaskStackListener;)V
    .registers 5

    :try_start_0
    invoke-virtual {p0, p1}, Landroid/app/ActivityTaskManager;->registerTaskStackListener(Landroid/app/TaskStackListener;)V
    :try_end_0
    .catch Ljava/lang/SecurityException; {:try_start_0 .. :try_end_0} :catch_0

    return-void

    :catch_0
    move-exception v0

    const-string v1, "GameKeysPort"

    const-string v2, "registerTaskStackListener ditolak, pakai polling getTasks"

    invoke-static {v1, v2}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;)I

    sget-object v0, Lorg/lineageos/gamekeys/service/PortTaskCompat;->sPoller:Ljava/lang/Thread;

    if-eqz v0, :start

    invoke-virtual {v0}, Ljava/lang/Thread;->interrupt()V

    :start
    new-instance v0, Ljava/lang/Thread;

    new-instance v1, Lorg/lineageos/gamekeys/service/PortTaskCompat;

    invoke-direct {v1, p0, p1}, Lorg/lineageos/gamekeys/service/PortTaskCompat;-><init>(Landroid/app/ActivityTaskManager;Landroid/app/TaskStackListener;)V

    const-string v2, "GameKeysTaskPoller"

    invoke-direct {v0, v1, v2}, Ljava/lang/Thread;-><init>(Ljava/lang/Runnable;Ljava/lang/String;)V

    const/4 v1, 0x1

    invoke-virtual {v0, v1}, Ljava/lang/Thread;->setDaemon(Z)V

    sput-object v0, Lorg/lineageos/gamekeys/service/PortTaskCompat;->sPoller:Ljava/lang/Thread;

    invoke-virtual {v0}, Ljava/lang/Thread;->start()V

    return-void
.end method

.method public static unregister(Landroid/app/ActivityTaskManager;Landroid/app/TaskStackListener;)V
    .registers 3

    sget-object v0, Lorg/lineageos/gamekeys/service/PortTaskCompat;->sPoller:Ljava/lang/Thread;

    if-eqz v0, :skip

    invoke-virtual {v0}, Ljava/lang/Thread;->interrupt()V

    const/4 v0, 0x0

    sput-object v0, Lorg/lineageos/gamekeys/service/PortTaskCompat;->sPoller:Ljava/lang/Thread;

    return-void

    :skip
    :try_start_0
    invoke-virtual {p0, p1}, Landroid/app/ActivityTaskManager;->unregisterTaskStackListener(Landroid/app/TaskStackListener;)V
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    return-void

    :catch_0
    move-exception v0

    return-void
.end method

.method public run()V
    .registers 8

    const/4 v0, 0x0

    :loop
    invoke-static {}, Ljava/lang/Thread;->currentThread()Ljava/lang/Thread;

    move-result-object v1

    invoke-virtual {v1}, Ljava/lang/Thread;->isInterrupted()Z

    move-result v1

    if-nez v1, :done

    :try_start_0
    iget-object v1, p0, Lorg/lineageos/gamekeys/service/PortTaskCompat;->atm:Landroid/app/ActivityTaskManager;

    const/4 v2, 0x1

    invoke-virtual {v1, v2, v2}, Landroid/app/ActivityTaskManager;->getTasks(IZ)Ljava/util/List;

    move-result-object v1

    if-eqz v1, :sleep

    invoke-interface {v1}, Ljava/util/List;->isEmpty()Z

    move-result v2

    if-nez v2, :sleep

    const/4 v2, 0x0

    invoke-interface {v1, v2}, Ljava/util/List;->get(I)Ljava/lang/Object;

    move-result-object v1

    check-cast v1, Landroid/app/ActivityManager$RunningTaskInfo;

    iget-object v2, v1, Landroid/app/ActivityManager$RunningTaskInfo;->topActivity:Landroid/content/ComponentName;

    if-eqz v2, :sleep

    invoke-virtual {v2}, Landroid/content/ComponentName;->getPackageName()Ljava/lang/String;

    move-result-object v2

    if-eqz v2, :sleep

    invoke-virtual {v2, v0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v3

    if-nez v3, :sleep

    move-object v0, v2

    iget-object v3, p0, Lorg/lineageos/gamekeys/service/PortTaskCompat;->listener:Landroid/app/TaskStackListener;

    invoke-virtual {v3, v1}, Landroid/app/TaskStackListener;->onTaskMovedToFront(Landroid/app/ActivityManager$RunningTaskInfo;)V
    :try_end_0
    .catch Ljava/lang/Throwable; {:try_start_0 .. :try_end_0} :catch_0

    :sleep
    :try_start_1
    const-wide/16 v4, 0x2bc

    invoke-static {v4, v5}, Ljava/lang/Thread;->sleep(J)V
    :try_end_1
    .catch Ljava/lang/InterruptedException; {:try_start_1 .. :try_end_1} :done
    .catch Ljava/lang/Throwable; {:try_start_1 .. :try_end_1} :loop

    goto :loop

    :catch_0
    move-exception v1

    const-string v2, "GameKeysPort"

    const-string v3, "polling task gagal"

    invoke-static {v2, v3, v1}, Landroid/util/Log;->w(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I

    goto :sleep

    :done
    return-void
.end method
