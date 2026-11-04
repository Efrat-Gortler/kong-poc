using BlockingService.Domain;
using Microsoft.EntityFrameworkCore;

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
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(32);
            e.Property(x => x.CallerId).HasMaxLength(256);
            e.Property(x => x.Route).HasMaxLength(128);
            e.Property(x => x.Reason).HasMaxLength(512);
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
