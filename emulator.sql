drop schema if exists private cascade;

create schema private;

create table private.constants
(
    id         integer primary key,
    label      varchar(20) not null,
    value      integer,
    value_word integer
);

create index idx_constants_label on private.constants (label);

create table private.registers
(
    id    integer primary key,
    value integer not null
);

create table private.state
(
    id         integer primary key,
    label      varchar(20) not null,
    value      integer,
    value_word integer
);

create table private.timers
(
    id    integer primary key,
    label varchar(20) not null,
    value integer     not null
);

create table private.inputs
(
    id    integer primary key,
    value integer not null
);

create table private.memory
(
    address integer primary key,
    value   integer not null
);

create table private.display
(
    i     integer primary key,
    value boolean
);

create table private.stack
(
    id    integer primary key,
    value integer not null
);

-- contains the current opcode and its parts for easy access
-- parts are: opcode, k, x, y, n, nn, nnn
create or replace view private.opcode_parts as
select s.value_word               as opcode,
       s.value_word & 61440 >> 12 as k,
       (s.value_word & 3840) >> 8 as x,
       (s.value_word & 240) >> 4  as y,
       s.value_word & 15          as n,
       s.value_word & 255         as nn,
       s.value_word & 4095        as nnn
from private.state s
where s.id = 4;

create or replace function private.reset()
    returns void as
$$
begin
    truncate table private.constants;
    insert into private.constants (id, label, value, value_word)
    values (1, 'Font Start', null, 61440),
           (2, 'Program Start', null, 512),
           (3, 'Screen Width', 64, null),
           (4, 'Screen Height', 32, null),
           (5, 'Register Count', 16, null),
           (6, 'Stack Depth', 16, null),
           (7, 'Input Count', 16, null);


    truncate table private.state;
    insert into private.state (id, label, value, value_word)
    values (1, 'Program Counter', null, (select value_word from private.constants where label = 'Program Start')),
           (2, 'Index Register', null, 0),
           (3, 'Stack Pointer', 0, null),
           (4, 'Opcode', null, 0),
           (5, 'Screen Dirty', 0, null);


    truncate table private.registers;
    insert into private.registers (id, value)
    select gs, 0
    from generate_series(0,
                         (select value from private.constants where label = 'Register Count') - 1) as gs;


    truncate table private.memory;
    insert into private.memory (address, value)
    select gs, 0
    from generate_series(0, 4095) as gs;


    truncate table private.display;
    insert into private.display (i, value)
    select gs, false
    from generate_series(0,
                         (select value from private.constants where label = 'Screen Width') *
                         (select value from private.constants where label = 'Screen Height') - 1) as gs;


    truncate table private.timers;
    insert into private.timers (id, label, value)
    values (1, 'Delay Timer', 0),
           (2, 'Sound Timer', 0);


    truncate table private.stack;
    insert into private.stack (id, value)
    select gs, 0
    from generate_series(0,
                         (select value from private.constants where label = 'Stack Depth') - 1) as gs;


    truncate table private.inputs;
    insert into private.inputs (id, value)
    select gs, 0
    from generate_series(0,
                         (select value from private.constants where label = 'Input Count') - 1) as gs;
end;
$$ language plpgsql;


create or replace function private.read_register(register_id integer)
    returns integer as
$$
declare
    reg_value integer;
begin
    select value
    into reg_value
    from private.registers
    where id = register_id;
    return reg_value;
end;
$$ language plpgsql;

create or replace function private.write_register(register_id integer, new_value integer)
    returns void as
$$
begin
    update private.registers
    set value = new_value
    where id = register_id;
end;
$$ language plpgsql;

create or replace function private.push_stack(new_value integer)
    returns void as
$$
begin
    -- stack[SP] = new_value
    update private.stack
    set value = new_value
    where id = (select value from private.state where id = 3);

    -- SP++
    update private.state
    set value = value + 1
    where id = 3;
end;
$$ language plpgsql;

create or replace function private.pop_stack()
    returns integer as
$$
declare
    stack_value integer;
begin
    -- SP--
    update private.state
    set value = value - 1
    where id = 3;

    -- return stack[SP]
    select value
    into stack_value
    from private.stack
    where id = (select value from private.state where id = 3);
    return stack_value;
end;
$$ language plpgsql;

create or replace function private.read_memory(read_address integer)
    returns integer as
$$
declare
    mem_value integer;
begin
    select value
    into mem_value
    from private.memory
    where address = read_address;
    return mem_value;
end;
$$ language plpgsql;

create or replace function private.write_memory(write_address integer, new_value integer)
    returns void as
$$
begin
    update private.memory
    set value = new_value
    where address = write_address;
end;
$$ language plpgsql;

create or replace function private.fetch()
    returns void as
$$
begin
    -- fetch the opcode at the current program counter
    update private.state
    set value_word =
            ((select value from private.memory where address = (select value_word from private.state where id = 1)) << 8)
                |
            (select value from private.memory where address = (select value_word from private.state where id = 1) + 1)
    where id = 4;
end;
$$ language plpgsql;

create or replace function private.increment_program_counter()
    returns void as
$$
begin
    update private.state
    set value_word = value_word + 2
    where id = 1;
end;
$$ language plpgsql;

-- section for opcode execution functions

-- JUMP
create or replace function private.exec_1nnn(op private.opcode_parts)
    returns void as
$$
begin
    update private.state
    set value_word = op.nnn
    where id = 1; -- Program Counter
end;
$$ language plpgsql;

-- CALL
create or replace function private.exec_2nnn(op private.opcode_parts)
    returns void as
$$
declare
    current_pc integer;
begin
    select value_word
    into current_pc
    from private.state
    where id = 1;

    perform private.push_stack(current_pc);

    update private.state
    set value_word = op.nnn
    where id = 1;
end;
$$ language plpgsql;


-- RETURN
create or replace function private.exec_group_0(op private.opcode_parts)
    returns void as
$$
begin
    if op.opcode = 238 then -- 0x00EE = 238 decimal
        update private.state
        set value_word = private.pop_stack()
        where id = 1;
    elsif op.opcode = 224 then -- 0x00E0 = 224 decimal
        update private.display
        set value = false;
    else
        raise exception 'Unknown 0-group opcode %', op.opcode;
    end if;
end;
$$ language plpgsql;

-- SET REGISTER
create or replace function private.exec_6xnn(op private.opcode_parts)
    returns void as
$$
begin
    update private.registers
    set value = op.nn
    where id = op.x;
end;
$$ language plpgsql;

-- ADD TO REGISTER
create or replace function private.exec_7xnn(op private.opcode_parts)
    returns void as
$$
begin
    update private.registers
    set value = (value + op.nn) % 256
    where id = op.x;
end;
$$ language plpgsql;

-- SKIP IF EQUAL
create or replace function private.exec_3xnn(op private.opcode_parts)
    returns void as
$$
declare
    vx integer;
begin
    select value
    into vx
    from private.registers
    where id = op.x;

    if vx = op.nn then
        update private.state
        set value_word = value_word + 2
        where id = 1;
    end if;
end;
$$ language plpgsql;

-- SKIP IF NOT EQUAL
create or replace function private.exec_4xnn(op private.opcode_parts)
    returns void as
$$
declare
    vx integer;
begin
    select value
    into vx
    from private.registers
    where id = op.x;

    if vx != op.nn then
        update private.state
        set value_word = value_word + 2
        where id = 1;
    end if;
end;
$$ language plpgsql;

-- SKIP IF REGISTERS EQUAL
create or replace function private.exec_5xy0(op private.opcode_parts)
    returns void as
$$
declare
    vx integer;
    vy integer;
begin
    select value into vx from private.registers where id = op.x;
    select value into vy from private.registers where id = op.y;

    if vx = vy then
        update private.state
        set value_word = value_word + 2
        where id = 1;
    end if;
end;
$$ language plpgsql;

-- SKIP IF REGISTERS NOT EQUAL
create or replace function private.exec_9xy0(op record)
    returns void as
$$
declare
    vx integer;
    vy integer;
begin
    select value into vx from private.registers where id = op.x;
    select value into vy from private.registers where id = op.y;

    if vx <> vy then
        update private.state set value_word = value_word + 2 where id = 1;
    end if;
end;
$$ language plpgsql;

-- ARITHMETIC AND BITWISE OPERATIONS
create or replace function private.exec_group_8(op record)
    returns void as
$$
declare
    vx     integer;
    vy     integer;
    result integer;
begin
    select value into vx from private.registers where id = op.x;
    select value into vy from private.registers where id = op.y;

    case op.n
        when 0 then update private.registers set value = vy where id = op.x;
        when 1 then update private.registers set value = (vx | vy) where id = op.x;
        when 2 then update private.registers set value = (vx & vy) where id = op.x;
        when 3 then update private.registers set value = (vx # vy) where id = op.x;
        when 4 then
            result := vx + vy;
            update private.registers set value = result % 256 where id = op.x;
            update private.registers set value = (result > 255)::int where id = 15;
        when 5 then
            update private.registers set value = (vx - vy + 256) % 256 where id = op.x;
            update private.registers set value = (vx >= vy)::int where id = 15;
        when 6 then
            update private.registers set value = vx >> 1 where id = op.x;
            update private.registers set value = (vx & 1) where id = 15;
        when 7 then
            update private.registers set value = (vy - vx + 256) % 256 where id = op.x;
            update private.registers set value = (vy >= vx)::int where id = 15;
        when 14 then
            update private.registers set value = (vx << 1) % 256 where id = op.x;
            update private.registers set value = ((vx & 128) >> 7) where id = 15;
        else raise exception 'Unknown 8xy? opcode %', op.opcode;
        end case;
end;
$$ language plpgsql;

-- SET INDEX REGISTER
create or replace function private.exec_annn(op record)
    returns void as
$$
begin
    update private.state set value_word = op.nnn where id = 2;
end;
$$ language plpgsql;

-- JUMP WITH OFFSET
create or replace function private.exec_bnnn(op record)
    returns void as
$$
declare
    v0 integer;
begin
    select value into v0 from private.registers where id = 0;

    update private.state
    set value_word = op.nnn + v0
    where id = 1;
end;
$$ language plpgsql;

-- RANDOM NUMBER
create or replace function private.exec_cxnn(op record)
    returns void as
$$
declare
    rnd integer;
begin
    rnd := floor(random() * 256);
    update private.registers
    set value = (rnd & op.nn)
    where id = op.x;
end;
$$ language plpgsql;

-- INPUT
create or replace function private.exec_group_e(op record)
    returns void as
$$
declare
    vx      integer;
    pressed integer;
begin
    select value into vx from private.registers where id = op.x;
    select value into pressed from private.inputs where id = vx;

    if op.nn = 158 then -- 9E
        if pressed = 1 then
            update private.state set value_word = value_word + 2 where id = 1;
        end if;

    elsif op.nn = 161 then -- A1
        if pressed = 0 then
            update private.state set value_word = value_word + 2 where id = 1;
        end if;

    else
        raise exception 'Unknown Ex?? opcode %', op.opcode;
    end if;
end;
$$ language plpgsql;

-- FGROUP
create or replace function private.exec_group_f(op record)
    returns void as
$$
declare
    vx integer;
    i  integer;
begin
    select value into vx from private.registers where id = op.x;
    select value_word into i from private.state where id = 2;

    case op.nn

        when 7 then -- Fx07
        update private.registers
        set value = (select value from private.timers where label = 'Delay Timer')
        where id = op.x;

        when 15 then -- Fx15
        update private.timers set value = vx where label = 'Delay Timer';

        when 18 then -- Fx18
        update private.timers set value = vx where label = 'Sound Timer';

        when 30 then -- Fx1E
        update private.state set value_word = i + vx where id = 2;

        when 41 then -- Fx29
        update private.state set value_word = vx * 5 where id = 2;

        when 51 then -- Fx33 (BCD)
        update private.memory set value = vx / 100 where address = i;
        update private.memory set value = (vx / 10) % 10 where address = i + 1;
        update private.memory set value = vx % 10 where address = i + 2;

        when 85 then -- Fx55
        for i in 0..op.x
            loop
                update private.memory
                set value = (select value from private.registers where id = i)
                where address = i + i;
            end loop;

        when 101 then -- Fx65
        for i in 0..op.x
            loop
                update private.registers
                set value = (select value from private.memory where address = i + i)
                where id = i;
            end loop;

        else raise exception 'Unknown Fx?? opcode %', op.opcode;
        end case;
end;
$$ language plpgsql;

create or replace function private.exec_dxyn(op record)
    returns void as
$$
declare
    vx          integer;
    vy          integer;
    i_reg           integer;
    sprite_row  integer;
    sprite_byte integer;
    x_pos       integer;
    y_pos       integer;
    pixel_idx   integer;
    old_pixel   boolean;
    collision   integer := 0;
    row         integer;
    col         integer;
begin
    -- fetch registers and I
    select value into vx from private.registers where id = op.x;
    select value into vy from private.registers where id = op.y;
    select value_word into i_reg from private.state where id = 2;

    -- clear VF
    update private.registers set value = 0 where id = 15;

    -- for each row of sprite
    for row in 0..op.n - 1
        loop
            -- read byte from memory
            select value into sprite_byte from private.memory where address = i_reg + row;

            -- draw each bit
            for col in 0..7
                loop
                    -- only process if bit is 1
                    if ((sprite_byte >> (7 - col)) & 1) = 1 then
                        -- calculate pixel coordinates (wrap)
                        x_pos := (vx + col) % 64;
                        y_pos := (vy + row) % 32;

                        pixel_idx := y_pos * 64 + x_pos;

                        -- get old pixel
                        select value into old_pixel from private.display where private.display.i = pixel_idx;

                        -- check collision
                        if old_pixel then
                            collision := 1;
                        end if;

                        -- XOR pixel
                        update private.display
                        set value = not old_pixel
                        where private.display.i = pixel_idx;
                    end if;
                end loop;
        end loop;

    -- set VF if any collision
    if collision = 1 then
        update private.registers set value = 1 where id = 15;
    end if;

    -- mark screen dirty
    update private.state
    set value = 1
    where id = 5;
end;
$$ language plpgsql;

-- exit section

create or replace function private.mark_screen_clean()
    returns void as
$$
begin
    update private.state
    set value = 0
    where id = 5;
end;
$$ language plpgsql;

create or replace function private.is_screen_dirty()
    returns boolean as
$$
declare
    dirty boolean;
begin
    select value::boolean
    into dirty
    from private.state
    where id = 5;
    return dirty;
end;
$$ language plpgsql;

create or replace function private.clock()
    returns void as
$$
declare
    op private.opcode_parts;
begin
    -- fetch
    perform private.fetch();
    perform private.increment_program_counter();

    -- opcode dispatch
    select *
    into op
    from private.opcode_parts;

    case op.k
        when 0 then perform private.exec_group_0(op);
        when 1 then perform private.exec_1nnn(op);
        when 2 then perform private.exec_2nnn(op);
        when 3 then perform private.exec_3xnn(op);
        when 4 then perform private.exec_4xnn(op);
        when 5 then perform private.exec_5xy0(op);
        when 6 then perform private.exec_6xnn(op);
        when 7 then perform private.exec_7xnn(op);
        when 8 then perform private.exec_group_8(op);
        when 9 then perform private.exec_9xy0(op);
        when 10 then perform private.exec_annn(op);
        when 11 then perform private.exec_bnnn(op);
        when 12 then perform private.exec_cxnn(op);
        when 13 then perform private.exec_dxyn(op);
        when 14 then perform private.exec_group_e(op);
        when 15 then perform private.exec_group_f(op);
        else raise exception 'Unknown opcode %', op.opcode;
        end case;

    -- decrement timers if they are above 0
    update private.timers
    set value = value - 1
    where value > 0;
end;
$$ language plpgsql;


select private.reset();

--select private.clock();