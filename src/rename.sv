// ============================================================================
//  rename.sv – RISC‑V Register‑Rename Module (combinational output)
//  - Single issue, single commit, single active branch (snapshot)
//  - Testbench reads rinstr_o **same cycle** -> output is purely combinational
// ============================================================================

module rename
#(
    parameter int unsigned ARCH_REGS  = 32,
    parameter int unsigned PHYS_REGS  = 64,
    parameter int unsigned P_IDX_W    = 6   // $clog2(PHYS_REGS)
)(
    input  logic       clk,
    input  logic       rst_ni,

    input  br_result_t br_result_i,
    input  p_reg_t     p_commit_i,
    input  dinstr_t    dinstr_i,

    output rinstr_t    rinstr_o,
    output logic       rn_full_o
);

// ---------------------------------------------------------------------------
// 1)  STATE REGISTERS
// ---------------------------------------------------------------------------
logic [P_IDX_W-1:0] rat            [ARCH_REGS];   // Register Alias Table
logic               phys_ready     [PHYS_REGS];   // Ready bit table
logic [P_IDX_W-1:0] free_q         [PHYS_REGS];   // Freelist FIFO storage
logic [$clog2(PHYS_REGS):0] free_head, free_tail, free_cnt;

// Branch snapshot
logic                         branch_active;
logic [P_IDX_W-1:0]           rat_snap        [ARCH_REGS];
logic                         phys_ready_snap [PHYS_REGS];
logic [$clog2(PHYS_REGS):0]   free_head_snap, free_tail_snap, free_cnt_snap;

// ---------------------------------------------------------------------------
// 2)  HELPER FLAGS (combinational)
// ---------------------------------------------------------------------------
logic alloc_needed, alloc_grant;
logic [P_IDX_W-1:0] new_preg;
logic taking_branch, branch_stall;
logic commit_fire, instr_accept;

assign alloc_needed  = dinstr_i.valid && dinstr_i.rd.valid && (dinstr_i.rd.idx != 5'd0);
assign alloc_grant   = (free_cnt != 0);
assign new_preg      = free_q[free_head[P_IDX_W-1:0]];
assign taking_branch = dinstr_i.valid && dinstr_i.is_branch && !branch_active;
assign branch_stall  = dinstr_i.valid && dinstr_i.is_branch && branch_active;
assign commit_fire   = p_commit_i.valid;
assign instr_accept  = dinstr_i.valid && !( (alloc_needed && !alloc_grant) || branch_stall );

assign rn_full_o     = (alloc_needed && !alloc_grant) || branch_stall;

// ---------------------------------------------------------------------------
// 3)  COMBINATIONAL RENAME LOGIC (no latches)
// ---------------------------------------------------------------------------
rinstr_t rinstr_n;
logic [P_IDX_W-1:0] idx1, idx2;  // blok dışı tanımlandı

always_comb begin
    // default/zap : no latch
    rinstr_n = '0;
    idx1 = '0;
    idx2 = '0;

    if (instr_accept) begin
        rinstr_n.valid = 1'b1;

        // ---------- RS1 ----------
        if (dinstr_i.rs1.valid) begin
            idx1 = rat[dinstr_i.rs1.idx];
            rinstr_n.rs1.valid = 1'b1;
            rinstr_n.rs1.idx   = idx1;
            rinstr_n.rs1.ready = phys_ready[idx1] ||
                                  (commit_fire && (p_commit_i.idx == idx1));
        end

        // ---------- RS2 ----------
        if (dinstr_i.rs2.valid) begin
            idx2 = rat[dinstr_i.rs2.idx];
            rinstr_n.rs2.valid = 1'b1;
            rinstr_n.rs2.idx   = idx2;
            rinstr_n.rs2.ready = phys_ready[idx2] ||
                                  (commit_fire && (p_commit_i.idx == idx2));
        end

        // ---------- RD ----------
        if (dinstr_i.rd.valid) begin
            rinstr_n.rd.valid = 1'b1;
            if (dinstr_i.rd.idx == 5'd0) begin
                rinstr_n.rd.idx   = '0; // p0 sabit
                rinstr_n.rd.ready = 1'b1;
            end else begin
                rinstr_n.rd.idx   = new_preg;
                rinstr_n.rd.ready = 1'b0;
            end
        end
    end
end

assign rinstr_o = rinstr_n;  // testbench aynı çevrimde okur

// ---------------------------------------------------------------------------
// 4)  SEQUENTIAL STATE UPDATE (posedge clk)
// ---------------------------------------------------------------------------

always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
        integer i;
        // RAT başlangıcı: x0→p0, x1→p1 ... x31→p31
        for (i=0; i<ARCH_REGS; i++) rat[i] <= i[P_IDX_W-1:0];
        // Ready bits = 1
        for (i=0; i<PHYS_REGS; i++) phys_ready[i] <= 1'b1;
        // Freelist: p32..p63
        for (i=0; i<PHYS_REGS-ARCH_REGS; i++) free_q[i] <= P_IDX_W'(ARCH_REGS+i);
        free_head <= '0;
        free_tail <= ($clog2(PHYS_REGS)+1)'(PHYS_REGS-ARCH_REGS);
        free_cnt  <= ($clog2(PHYS_REGS)+1)'(PHYS_REGS-ARCH_REGS);
        branch_active <= 1'b0;
    end else begin
        // -- COMMIT --
        if (commit_fire) begin
            phys_ready[p_commit_i.idx] <= 1'b1;
            free_q[free_tail[P_IDX_W-1:0]] <= p_commit_i.idx;
            free_tail <= free_tail + 1;
            free_cnt  <= free_cnt  + 1;
        end

        // -- BRANCH RESULT --
        if (br_result_i.valid && branch_active) begin
            branch_active <= 1'b0;
            if (!br_result_i.hit) begin
                integer j;
                for (j=0; j<ARCH_REGS; j++) rat[j] <= rat_snap[j];
                for (j=0; j<PHYS_REGS; j++) phys_ready[j] <= phys_ready_snap[j];
                free_head <= free_head_snap;
                free_tail <= free_tail_snap;
                free_cnt  <= free_cnt_snap;
            end
        end

        // -- ACCEPTED INSTRUCTION --
        if (instr_accept) begin
            if (alloc_needed && alloc_grant) begin
                rat[dinstr_i.rd.idx] <= new_preg;
                phys_ready[new_preg] <= 1'b0;
                free_head <= free_head + 1;
                free_cnt  <= free_cnt  - 1;
            end
            if (taking_branch) begin
                integer k;
                for (k=0; k<ARCH_REGS; k++) rat_snap[k] <= rat[k];
                for (k=0; k<PHYS_REGS; k++) phys_ready_snap[k] <= phys_ready[k];
                free_head_snap <= free_head;
                free_tail_snap <= free_tail;
                free_cnt_snap  <= free_cnt;
                branch_active  <= 1'b1;
            end
        end
    end
end

endmodule
