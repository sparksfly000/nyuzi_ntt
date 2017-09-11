//
// Copyright 2011-2015 Jeff Bush
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

`include "defines.sv"

//
// This prints register updates and memory writes to the console. The emulator
// uses this information to verify the hardware is working correctly in
// cosimulation.
//
// This captures instructions as the pipeline retires them. This is necessary
// to get the results of arithmetic operations. The problem is that the
// pipeline doesn't always retire instructions in program order like the
// emulator. To be able to compare the results, this uses a queue to reorder
// instructions and logs them in issue order.
//

module trace_logger(
    input                            clk,
    input                            reset,

    // From writeback stage
    input                            wb_writeback_en,
    input                            wb_writeback_is_vector,
    input thread_idx_t               wb_writeback_thread_idx,
    input register_idx_t             wb_writeback_reg,
    input vector_t                   wb_writeback_value,
    input vector_lane_mask_t         wb_writeback_mask,
    input thread_idx_t               wb_rollback_thread_idx,
    input scalar_t                   wb_trap_pc,
    input scalar_t                   wb_rollback_pc,
    input                            debug_is_sync_store,
    input pipeline_sel_t             debug_wb_pipeline,
    input scalar_t                   debug_wb_pc,

    // From integer pipeline
    input                            ix_instruction_valid,
    input                            ix_instruction_has_dest,
    input register_idx_t             ix_instruction_dest_reg,
    input                            ix_instruction_dest_is_vector,
    input scalar_t                   ix_instruction_pc,
    input                            ix_instruction_has_trap,
    input trap_cause_t               ix_instruction_trap_cause,


    // From memory pipeline
    input                            dd_instruction_valid,
    input                            dd_instruction_has_dest,
    input register_idx_t             dd_instruction_dest_reg,
    input                            dd_instruction_dest_is_vector,
    input                            dd_rollback_en,
    input scalar_t                   dd_instruction_pc,
    input                            dd_store_en,
    input [`CACHE_LINE_BYTES - 1:0]  dd_store_mask,
    input vector_t                   dd_store_data,
    input                            dd_instruction_is_load,
    input memory_op_t                dd_instruction_memory_access_type,
    input scalar_t                   dt_instruction_pc,
    input thread_idx_t               dt_thread_idx,
    input scalar_t                   dt_request_virt_addr,
    input                            sq_rollback_en,
    input                            sq_store_sync_success);

    localparam TRACE_REORDER_QUEUE_LEN = 7;

    typedef enum logic [2:0] {
        EVENT_INVALID = 0,
        EVENT_SWRITEBACK,
        EVENT_VWRITEBACK,
        EVENT_STORE,
        EVENT_INTERRUPT
    } trace_event_type_t;

    typedef struct packed {
        trace_event_type_t event_type;
        scalar_t pc;
        thread_idx_t thread_idx;
        register_idx_t writeback_reg;
        scalar_t addr;
        logic[`CACHE_LINE_BYTES - 1:0] mask;
        vector_t data;
    } trace_event_t;

    trace_event_t trace_reorder_queue[TRACE_REORDER_QUEUE_LEN];
    bit trace_en;

    initial
    begin
        trace_en = $test$plusargs("trace") != 0;
    end

    always_ff @(posedge clk, posedge reset)
    begin
        if (reset)
        begin
            for (int i = 0; i < TRACE_REORDER_QUEUE_LEN; i++)
                trace_reorder_queue[i] <= 0;
        end
        else if (trace_en)
        begin
            case (trace_reorder_queue[0].event_type)
                EVENT_VWRITEBACK:
                begin
                    $display("vwriteback %x %x %x %x %x",
                        trace_reorder_queue[0].pc,
                        trace_reorder_queue[0].thread_idx,
                        trace_reorder_queue[0].writeback_reg,
                        trace_reorder_queue[0].mask,
                        trace_reorder_queue[0].data);
                end

                EVENT_SWRITEBACK:
                begin
                    $display("swriteback %x %x %x %x",
                        trace_reorder_queue[0].pc,
                        trace_reorder_queue[0].thread_idx,
                        trace_reorder_queue[0].writeback_reg,
                        trace_reorder_queue[0].data[0]);
                end

                EVENT_STORE:
                begin
                    $display("store %x %x %x %x %x",
                        trace_reorder_queue[0].pc,
                        trace_reorder_queue[0].thread_idx,
                        trace_reorder_queue[0].addr,
                        trace_reorder_queue[0].mask,
                        trace_reorder_queue[0].data);
                end

                EVENT_INTERRUPT:
                begin
                    $display("interrupt %d %x", trace_reorder_queue[0].thread_idx,
                        trace_reorder_queue[0].pc);
                end

                default:
                    ; // Do nothing
            endcase

            for (int i = 0; i < TRACE_REORDER_QUEUE_LEN - 1; i++)
                trace_reorder_queue[i] <= trace_reorder_queue[i + 1];

            trace_reorder_queue[TRACE_REORDER_QUEUE_LEN - 1] <= 0;

            // Note that we only record the memory event for a synchronized store, not the register
            // success value.
            if (wb_writeback_en && !debug_is_sync_store)
            begin : dump_trace_event
                int tindex;

                if (debug_wb_pipeline == PIPE_SCYCLE_ARITH)
                    tindex = 4;
                else if (debug_wb_pipeline == PIPE_MEM)
                    tindex = 3;
                else // Multicycle arithmetic
                    tindex = 0;

                assert(trace_reorder_queue[tindex + 1].event_type == EVENT_INVALID);
                if (wb_writeback_is_vector)
                    trace_reorder_queue[tindex].event_type <= EVENT_VWRITEBACK;
                else
                    trace_reorder_queue[tindex].event_type <= EVENT_SWRITEBACK;

                trace_reorder_queue[tindex].pc <= debug_wb_pc;
                trace_reorder_queue[tindex].thread_idx <= wb_writeback_thread_idx;
                trace_reorder_queue[tindex].writeback_reg <= wb_writeback_reg;
                trace_reorder_queue[tindex].mask <= {{`CACHE_LINE_BYTES - `VECTOR_LANES{1'b0}},
                    wb_writeback_mask};
                trace_reorder_queue[tindex].data <= wb_writeback_value;
            end

            // Handle PC destination.
            if (ix_instruction_valid
                && ix_instruction_has_dest
                && ix_instruction_dest_reg == `REG_PC
                && !ix_instruction_dest_is_vector)
            begin
                assert(trace_reorder_queue[6].event_type == EVENT_INVALID);
                trace_reorder_queue[5].event_type <= EVENT_SWRITEBACK;
                trace_reorder_queue[5].pc <= ix_instruction_pc;
                trace_reorder_queue[5].thread_idx <= wb_rollback_thread_idx;
                trace_reorder_queue[5].writeback_reg <= 31;
                trace_reorder_queue[5].data[0] <= wb_rollback_pc;
            end
            else if (dd_instruction_valid
                && dd_instruction_has_dest
                && dd_instruction_dest_reg == `REG_PC
                && !dd_instruction_dest_is_vector
                && !dd_rollback_en)
            begin
                assert(trace_reorder_queue[5].event_type == EVENT_INVALID);
                trace_reorder_queue[4].event_type <= EVENT_SWRITEBACK;
                trace_reorder_queue[4].pc <= dd_instruction_pc;
                trace_reorder_queue[4].thread_idx <= wb_rollback_thread_idx;
                trace_reorder_queue[4].writeback_reg <= 31;
                trace_reorder_queue[4].data[0] <= wb_rollback_pc;
            end

            if (dd_store_en)
            begin
                assert(trace_reorder_queue[6].event_type == EVENT_INVALID);
                trace_reorder_queue[5].event_type <= EVENT_STORE;
                trace_reorder_queue[5].pc <= dt_instruction_pc;
                trace_reorder_queue[5].thread_idx <= dt_thread_idx;
                trace_reorder_queue[5].addr <= {
                    dt_request_virt_addr[31:`CACHE_LINE_OFFSET_WIDTH],
                    {`CACHE_LINE_OFFSET_WIDTH{1'b0}}
                };
                trace_reorder_queue[5].mask <= dd_store_mask;
                trace_reorder_queue[5].data <= dd_store_data;
            end

            // Invalidate the store instruction if it was rolled back.
            if (sq_rollback_en && dd_instruction_valid)
                trace_reorder_queue[4].event_type <= EVENT_INVALID;

            // Invalidate the store instruction if a synchronized store failed
            if (dd_instruction_valid
                && dd_instruction_memory_access_type == MEM_SYNC
                && !dd_instruction_is_load
                && !sq_store_sync_success)
                trace_reorder_queue[4].event_type <= EVENT_INVALID;

            // Signal interrupt to emulator. These are piggybacked on instructions
            // and flow down the integer pipeline.
            if (ix_instruction_valid && ix_instruction_has_trap
                && ix_instruction_trap_cause.trap_type == TT_INTERRUPT)
            begin
                assert(trace_reorder_queue[6].event_type == EVENT_INVALID);
                trace_reorder_queue[5].event_type <= EVENT_INTERRUPT;
                trace_reorder_queue[5].thread_idx <= wb_rollback_thread_idx;
                trace_reorder_queue[5].pc <= wb_trap_pc;
            end
        end
    end
endmodule
