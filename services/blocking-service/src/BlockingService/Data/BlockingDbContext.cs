using BlockingService.Domain;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Storage;

namespace BlockingService.Data;

public class BlockingDbContext(DbContextOptions<BlockingDbContext> options) : DbContext(options)
{
    public DbSet<Block> Blocks => Set<Block>();
    public DbSet<AuditEntry> Audit => Set<AuditEntry>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        b.Entity<Block>(e =>
        {
            e.ToTable("blocks");
            e.HasKey(x => x.Id);
            e.Ignore(x => x.RuleKey);
            e.Property(x => x.SubjectType).HasConversion<string>().HasMaxLength(16);
            e.Property(x => x.SubjectId).HasMaxLength(BlockValidator.MaxIdLength);
            e.Property(x => x.Route).HasMaxLength(128);
            e.Property(x => x.Reason).HasMaxLength(BlockValidator.MaxReasonLength);
            e.Property(x => x.CreatedBy).HasMaxLength(256);
            e.Property(x => x.RemovedBy).HasMaxLength(256);
            e.HasIndex(x => x.RemovedAt);
        });
        b.Entity<AuditEntry>(e =>
        {
            e.ToTable("audit");
            e.HasKey(x => x.Id);
            e.Property(x => x.Action).HasMaxLength(16);
            e.Property(x => x.Actor).HasMaxLength(256);
            e.HasIndex(x => x.At);
        });
    }
}

/// <summary>
/// Schema handling for the POC (no EF migration tooling, see README "Deviations").
/// v1 (Kind/CallerId columns) -> v2 (SubjectType/SubjectId): the v1 tables are RENAMED to
/// blocks_v1 / audit_v1 (kept read-only for the audit trail, not migrated - v1 blocks are not
/// enforced any more) and empty v2 tables are created. A fresh database just gets v2.
/// Production: EF Core migrations (dotnet ef migrations bundle) instead.
/// </summary>
public static class Schema
{
    public static async Task EnsureCurrentAsync(BlockingDbContext db, ILogger log)
    {
        await db.Database.EnsureCreatedAsync();   // fresh database: creates v2, done

        var v1 = await Exists(db, """
            SELECT EXISTS (SELECT 1 FROM information_schema.columns
                           WHERE table_schema = current_schema() AND table_name = 'blocks' AND column_name = 'Kind') AS "Value"
            """);
        if (v1)
        {
            log.LogWarning("Blocking DB schema v1 found: renaming blocks -> blocks_v1, audit -> audit_v1 and creating schema v2 (v1 blocks are no longer enforced)");
            await db.Database.ExecuteSqlRawAsync("""
                ALTER TABLE blocks RENAME TO blocks_v1;
                ALTER TABLE blocks_v1 RENAME CONSTRAINT "PK_blocks" TO "PK_blocks_v1";
                ALTER INDEX IF EXISTS "IX_blocks_RemovedAt" RENAME TO "IX_blocks_v1_RemovedAt";
                ALTER TABLE IF EXISTS audit RENAME TO audit_v1;
                ALTER TABLE IF EXISTS audit_v1 RENAME CONSTRAINT "PK_audit" TO "PK_audit_v1";
                ALTER INDEX IF EXISTS "IX_audit_At" RENAME TO "IX_audit_v1_At";
                """);
        }
        var haveBlocks = await Exists(db, """
            SELECT EXISTS (SELECT 1 FROM information_schema.tables
                           WHERE table_schema = current_schema() AND table_name = 'blocks') AS "Value"
            """);
        if (!haveBlocks)
        {
            // EnsureCreated does nothing once any table exists, so create the model's tables directly
            await db.GetService<IRelationalDatabaseCreator>().CreateTablesAsync();
            log.LogInformation("Blocking DB schema v2 created");
        }
    }

    private static async Task<bool> Exists(BlockingDbContext db, string sql) =>
        await db.Database.SqlQueryRaw<bool>(sql).SingleAsync();
}
