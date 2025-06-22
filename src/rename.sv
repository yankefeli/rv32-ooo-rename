`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 15.06.2025 21:46:31
// Design Name: 
// Module Name: rename
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


// ============================================================================
//  rename.sv  -  RISC-V Out-of-Order  •  Register-Rename Module (branch-aware)
// ============================================================================
//  Tek-issue, in-order commit, **tek aktif branch** desteği.
//
//  Gereksinimler:
//  • Sahte bağımlılıkları önlemek için register renaming
//  • x0 daima p0
//  • rn_full_o HIGH  ⇒  işlemci stall (freelist boş **veya** ikinci branch denemesi)
//  • Branch miss → RAT + freelist + phys_ready restore (snapshot)
//
//  Not: Bu tasarım 1-cycle latency sunar (rinstr_o bir sonraki saat çıkar).
//  Çoklu-issue veya çok-cycle latency gerekirse ek portlanabilir.
// ============================================================================

// ---------------------------------------------------------------------------
// 1)  TYPE DEFINITIONS  (ödev şartnamesiyle bire bir)
// ---------------------------------------------------------------------------
typedef struct packed {
    logic       valid;
    logic [4:0] idx;          // architectural register id
} a_reg_t;                     // architectural register

typedef struct packed {
    logic       valid;
    a_reg_t     rd;
    a_reg_t     rs1;
    a_reg_t     rs2;
    logic       is_branch;     // bonus
} dinstr_t;                    // decoded instruction

typedef struct packed {
    logic       valid;
    logic [5:0] idx;           // physical register id
    logic       ready;
} p_reg_t;                     // physical register

typedef struct packed {
    logic       valid;
    p_reg_t     rd;
    p_reg_t     rs1;
    p_reg_t     rs2;
} rinstr_t;                    // renamed instruction

typedef struct packed {
    logic valid;
    logic hit;                 // 1 → doğru tahmin; 0 → mis-predict
} br_result_t;

// ---------------------------------------------------------------------------
// 2)  MODULE DECLARATION
// ---------------------------------------------------------------------------
module rename
#(
    parameter int unsigned ARCH_REGS  = 32,
    parameter int unsigned PHYS_REGS  = 64,
    parameter int unsigned P_IDX_W    = 6       // $clog2(PHYS_REGS)
)(
    input  logic       clk,
    input  logic       rst_ni,

    // Branch sonucu (gecikmeli gelir)
    input  br_result_t br_result_i,

    // In-order commit hattı (tek p-reg)
    input  p_reg_t     p_commit_i,

    // Decode'den gelen komut
    input  dinstr_t    dinstr_i,

    // Yeniden adlandırılmış komut (1-cycle latency)
    output rinstr_t    rinstr_o,

    // Stall göstergesi
    output logic       rn_full_o
);

// -----------------------------------------------------------------------
// 3)  INTERNAL STATE
// -----------------------------------------------------------------------

// 3.1  Register Aliasing Table (RAT): arch idx -> phys idx
logic [P_IDX_W-1:0] rat          [ARCH_REGS];

// 3.2  Physical-register ready bits (Busy Table)
logic               phys_ready   [PHYS_REGS];

// 3.3  Free-list (dairevi FIFO)
logic [P_IDX_W-1:0] free_q       [PHYS_REGS];
logic [$clog2(PHYS_REGS):0] free_head, free_tail, free_cnt;

// 3.4  Branch snapshot  (tek aktif branch)
logic                         branch_active;
logic [P_IDX_W-1:0]           rat_snap      [ARCH_REGS];
logic                         phys_ready_snap [PHYS_REGS];
logic [$clog2(PHYS_REGS):0]   free_head_snap, free_tail_snap, free_cnt_snap;

// -----------------------------------------------------------------------
// 4)  COMBINATIONAL HELPERS (geçerli çevrimde hesaplananlar)
// -----------------------------------------------------------------------

// Freelist durum
logic alloc_needed;            // bu çevrim yeni p-reg gerekiyor mu?
logic alloc_grant;             // freelist'te en az bir eleman var
logic [P_IDX_W-1:0] new_preg;

// Branch ile ilişkili sinyaller
logic taking_branch;           // bu çevrim branch komutu kabul ediliyor mu?
logic branch_stall;            // ikinci branch geldi → stall

// Commit hattı
logic commit_fire;
assign commit_fire = p_commit_i.valid;

// -----------------------------------------------------------------------
// 5)  RESET - INITIAL MAP & FREELIST
// -----------------------------------------------------------------------

always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
        integer i;

        // RAT başlangıcı - arch_i → phys_i
        for (i = 0; i < ARCH_REGS; i++) begin
            rat[i] <= logic'(i[P_IDX_W-1:0]);
        end

        // Ready bitleri = 1
        for (i = 0; i < PHYS_REGS; i++) begin
            phys_ready[i] <= 1'b1;
        end

        // freelist = p32..p63
        for (i = 0; i < (PHYS_REGS-ARCH_REGS); i++) begin
            free_q[i] <= logic'(ARCH_REGS + i);
        end
        free_head <= '0;
        free_tail <= logic'(PHYS_REGS - ARCH_REGS);
        free_cnt  <= logic'(PHYS_REGS - ARCH_REGS);

        // branch durumu
        branch_active <= 1'b0;
    end
    
    else begin
        // ---------------------------------------------------------------
        // 5.1  COMMIT: ready set + freelist enqueue
        // ---------------------------------------------------------------
        if (commit_fire) begin
            phys_ready[p_commit_i.idx] <= 1'b1;

            // Commit edilen p-reg'i freelist'e geri at
            free_q[free_tail] <= p_commit_i.idx;
            free_tail         <= free_tail + 1;
            free_cnt          <= free_cnt + 1;
        end

        // ---------------------------------------------------------------
        // 5.2  BRANCH MISS / HIT  (öncelik: restore önce)
        // ---------------------------------------------------------------
        if (br_result_i.valid && branch_active) begin
            branch_active <= 1'b0;   // branch artık kapandı

            if (!br_result_i.hit) begin : restore_path
                integer j;
                // RAT restore
                for (j = 0; j < ARCH_REGS; j++) begin
                    rat[j] <= rat_snap[j];
                end
                // ready restore
                for (j = 0; j < PHYS_REGS; j++) begin
                    phys_ready[j] <= phys_ready_snap[j];
                end
                // freelist pointer restore
                free_head <= free_head_snap;
                free_tail <= free_tail_snap;
                free_cnt  <= free_cnt_snap;
            end
        end

        // ---------------------------------------------------------------
        // 5.3  RENAME ACCEPT PATH (yalnızca stall yoksa)
        // ---------------------------------------------------------------
        //  Outgoing signals hesaplandıktan sonra `instr_accept` flag'i ile
        //  aşağıdaki güncellemeler yapılır.
        // ---------------------------------------------------------------
    end
end // always_ff reset / main

// -----------------------------------------------------------------------
// 6)  COMBINATIONAL RENAME & STALL LOGIC
// -----------------------------------------------------------------------
rinstr_t rinstr_n;
logic     instr_accept;

// Freelist durumu
assign alloc_needed = dinstr_i.valid && dinstr_i.rd.valid && (dinstr_i.rd.idx != 5'd0);
assign alloc_grant  = (free_cnt != 0);
assign new_preg     = free_q[free_head];

// Branch kontrolü
assign taking_branch = dinstr_i.valid && dinstr_i.is_branch && !branch_active;
assign branch_stall  = dinstr_i.valid && dinstr_i.is_branch && branch_active;

// Global stall koşulu
assign rn_full_o = (alloc_needed && !alloc_grant) || branch_stall;
assign instr_accept = dinstr_i.valid && !rn_full_o;

// Default çıkışlar
always_comb begin
    rinstr_n = '0;

    // Stall durumunda geçersiz komut çıkarıyoruz
    if (instr_accept) begin
        rinstr_n.valid = 1'b1;

        // ------------------- RS1 -------------------
        if (dinstr_i.rs1.valid) begin
            rinstr_n.rs1.valid = 1'b1;
            rinstr_n.rs1.idx   = rat[dinstr_i.rs1.idx];
            rinstr_n.rs1.ready = phys_ready[rinstr_n.rs1.idx] ||
                                  (commit_fire && (p_commit_i.idx == rinstr_n.rs1.idx));
        end

        // ------------------- RS2 -------------------
        if (dinstr_i.rs2.valid) begin
            rinstr_n.rs2.valid = 1'b1;
            rinstr_n.rs2.idx   = rat[dinstr_i.rs2.idx];
            rinstr_n.rs2.ready = phys_ready[rinstr_n.rs2.idx] ||
                                  (commit_fire && (p_commit_i.idx == rinstr_n.rs2.idx));
        end

        // ------------------- RD --------------------
        if (dinstr_i.rd.valid) begin
            rinstr_n.rd.valid = 1'b1;

            if (dinstr_i.rd.idx == 5'd0) begin         // x0 özel
                rinstr_n.rd.idx   = '0;
                rinstr_n.rd.ready = 1'b1;
            end
            
            else begin
                rinstr_n.rd.idx   = new_preg;
                rinstr_n.rd.ready = 1'b0;
            end
            
        end
    end
end

// -----------------------------------------------------------------------
// 7)  STATE UPDATE ON ACCEPTED INSTRUCTION
// -----------------------------------------------------------------------

always_ff @(posedge clk) begin : state_update
    if (rst_ni && instr_accept) begin
        //---------------------------------------------------------------
        // 7.1  Allocation / RAT write (eğer gerekiyorsa)
        //---------------------------------------------------------------
        if (alloc_needed && alloc_grant) begin
            rat[dinstr_i.rd.idx] <= new_preg;
            phys_ready[new_preg] <= 1'b0;      // henüz yazılmadı
            // freelist de-queue
            free_head <= free_head + 1;
            free_cnt  <= free_cnt  - 1;
        end

        //---------------------------------------------------------------
        // 7.2  Branch snapshot (ilk branch kabulü)
        //---------------------------------------------------------------
        if (taking_branch) begin
            integer k;
            for (k = 0; k < ARCH_REGS; k++) begin
                rat_snap[k] <= rat[k];
            end
            for (k = 0; k < PHYS_REGS; k++) begin
                phys_ready_snap[k] <= phys_ready[k];
            end

            free_head_snap <= free_head;
            free_tail_snap <= free_tail;
            free_cnt_snap  <= free_cnt;

            branch_active <= 1'b1;
        end
    end
end

// -----------------------------------------------------------------------
// 8)  OUTPUT REGISTER  (1-cycle latency)
// -----------------------------------------------------------------------
rinstr_t rinstr_q;

always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
        rinstr_q <= '0;
    end else begin
        rinstr_q <= rinstr_n;
    end
end

assign rinstr_o = rinstr_q;

endmodule
