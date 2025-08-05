module dbus

import sync
import context
import io
import os
import strings

// Type aliases for D-Bus types
type ObjectPath = string
type UnixFD = i32
type UnixFDIndex = u32

// Signature represents a D-Bus type signature
struct Signature {
	str string
}

// Variant represents a D-Bus variant type
struct Variant {
	signature Signature
	value     voidptr
}

// InvalidTypeError signals that a value cannot be represented in D-Bus wire format
struct InvalidTypeError {
	type_name string
}

fn (e InvalidTypeError) msg() string {
	return 'dbus: invalid type ${e.type_name}'
}

// D-Bus message types
enum MessageType {
	type_invalid      = 0
	type_method_call  = 1
	type_method_reply = 2
	type_error        = 3
	type_signal       = 4
}

// D-Bus header fields
enum HeaderField {
	field_invalid     = 0
	field_path        = 1
	field_interface   = 2
	field_member      = 3
	field_error_name  = 4
	field_reply_serial = 5
	field_destination = 6
	field_sender      = 7
	field_signature   = 8
	field_unix_fds    = 9
}

// Message flags
enum MessageFlag {
	flag_no_reply_expected = 0x1
	flag_no_auto_start     = 0x2
	flag_allow_interactive_authorization = 0x4
}

// Message represents a D-Bus message
struct Message {
mut:
	msg_type MessageType
	flags    u8
	version  u8
	serial   u32
	headers  map[HeaderField]Variant
	body     []voidptr
}

// DBusError represents a D-Bus error
struct DBusError {
	name string
	body []voidptr
}

fn (e DBusError) msg() string {
	if e.body.len >= 1 && e.body[0] != unsafe { nil } {
		// Try to cast to string - in real implementation you'd have proper type checking
		s := unsafe { *(&string(e.body[0])) }
		return s
	}
	return e.name
}

fn new_dbus_error(name string, body []voidptr) &DBusError {
	return &DBusError{
		name: name
		body: body
	}
}

// Signal represents a D-Bus signal
struct Signal {
	sender   string
	path     ObjectPath
	name     string
	body     []voidptr
	sequence Sequence
}

// Sequence represents message sequence number
type Sequence = u64

const no_sequence = Sequence(0)

// Call represents a pending or completed method call
@[heap]
struct Call {
mut:
	destination        string
	path               ObjectPath
	method             string
	args               []voidptr
	body               []voidptr
	err                ?DBusError
	done_chan          chan &Call
	response_sequence  Sequence
	ctx                context.Context
	ctx_canceler       ?fn()
}

fn (c &Call) done() {
	if c.done_chan.len < c.done_chan.cap {
		c.done_chan <- c
	}
}

// Transport interface for D-Bus connections
interface Transport {
	read(mut buf []u8) ?int
	write(buf []u8) ?int
	close() ?
	send_null_byte() ?
	supports_unix_fds() bool
	enable_unix_fds()
	read_message() ?&Message
	send_message(msg &Message) ?
}

// Handler interface for method calls
interface Handler {
	handle_call(msg &Message) 
}

// SignalHandler interface for signals
interface SignalHandler {
	deliver_signal(iface string, member string, signal &Signal)
}

// SignalRegistrar interface for signal registration
interface SignalRegistrar {
	add_signal(ch chan &Signal)
	remove_signal(ch chan &Signal)
}

// Terminator interface for cleanup
interface Terminator {
	terminate()
}

// BusObject represents a remote D-Bus object
interface BusObject {
	call(method string, flags u8, args ...voidptr) &Call
	call_with_context(ctx context.Context, method string, flags u8, args ...voidptr) &Call
	go_call(method string, flags u8, ch chan &Call, args ...voidptr) &Call
}

// Object represents a D-Bus object
struct Object {
	conn &Conn
	dest string
	path ObjectPath
}

fn (o &Object) call(method string, flags u8, args ...voidptr) &Call {
	return o.call_with_context(context.background(), method, flags, ...args)
}

fn (o &Object) call_with_context(ctx context.Context, method string, flags u8, args ...voidptr) &Call {
	msg := &Message{
		msg_type: .type_method_call
		flags: flags
		headers: map[HeaderField]Variant{}
		body: args
	}
	
	msg.headers[.field_destination] = make_variant(o.dest)
	msg.headers[.field_path] = make_variant(o.path)
	
	// Split method into interface and member
	parts := method.split('.')
	if parts.len >= 2 {
		member := parts.last()
		iface := parts[..parts.len-1].join('.')
		msg.headers[.field_interface] = make_variant(iface)
		msg.headers[.field_member] = make_variant(member)
	}
	
	if args.len > 0 {
		msg.headers[.field_signature] = make_variant(signature_of(...args))
	}
	
	return o.conn.send_with_context(ctx, msg, chan &Call{cap: 1})
}

fn (o &Object) go_call(method string, flags u8, ch chan &Call, args ...voidptr) &Call {
	return o.call_with_context(context.background(), method, flags, ...args)
}

// Connection options
type ConnOption = fn(mut conn Conn) !

fn  with_handler(handler Handler) ConnOption {
	return fn[handler](mut conn Conn) ! {
		conn.handler = handler
	}
}

fn with_signal_handler(handler SignalHandler) ConnOption {
	return fn [handler](mut conn Conn) ! {
		conn.signal_handler = handler
	}
}

fn with_context(ctx context.Context) ConnOption {
	return fn[ctx](mut conn Conn) ! {
		conn.ctx = ctx
	}
}

// SerialGenerator generates unique message serials
struct SerialGenerator {
mut:
	mutex       sync.Mutex
	next_serial u32 = 1
	serial_used map[u32]bool
}

fn new_serial_generator() &SerialGenerator {
	mut gen := &SerialGenerator{
		serial_used: {u32(0): true}
	}
	return gen
}

fn (mut gen SerialGenerator) get_serial() u32 {
	gen.mutex.@lock()
	defer { gen.mutex.unlock() }
	
	mut n := gen.next_serial
	
	// Keep incrementing until we find an unused serial number
	for {
		if used := gen.serial_used[n] {
			if used {
				n++
				continue
			}
		}
		// Found an unused serial number
		break
	}
	
	gen.serial_used[n] = true
	gen.next_serial = n + 1
	return n
}

fn (mut gen SerialGenerator) retire_serial(serial u32) {
	gen.mutex.@lock()
	defer { gen.mutex.unlock() }
	gen.serial_used.delete(serial)
}

// NameTracker tracks owned names
struct NameTracker {
mut:
	mutex  sync.RwMutex
	unique string
	names  map[string]bool
}

fn new_name_tracker() &NameTracker {
	return &NameTracker{
		names: map[string]bool{}
	}
}

fn (mut nt NameTracker) acquire_unique_connection_name(name string) {
	nt.mutex.@lock()
	defer { nt.mutex.unlock() }
	nt.unique = name
}

fn (mut nt NameTracker) acquire_name(name string) {
	nt.mutex.@lock()
	defer { nt.mutex.unlock() }
	nt.names[name] = true
}

fn (mut nt NameTracker) lose_name(name string) {
	nt.mutex.@lock()
	defer { nt.mutex.unlock() }
	nt.names.delete(name)
}

fn (mut nt NameTracker) is_known_name(name string) bool {
	nt.mutex.@rlock()
	defer { nt.mutex.runlock() }
	return (name in nt.names) || name == nt.unique
}

fn (mut nt NameTracker) list_known_names() []string {
	nt.mutex.@rlock()
	defer { nt.mutex.runlock() }
	mut out := []string{cap: nt.names.len + 1}
	out << nt.unique
	for name, _ in nt.names {
		out << name
	}
	return out
}

// CallTracker tracks pending method calls
struct CallTracker {
mut:
	mutex sync.RwMutex
	calls map[u32]&Call
}

fn new_call_tracker() &CallTracker {
	return &CallTracker{
		calls: map[u32]&Call{}
	}
}

fn (mut ct CallTracker) track(serial u32, call &Call) {
	ct.mutex.@lock()
	defer { ct.mutex.unlock() }
	ct.calls[serial] = call
}

fn (mut ct CallTracker) handle_reply(sequence Sequence, msg &Message) u32 {
	serial := get_reply_serial(msg) or { return 0 }
	ct.mutex.@rlock()
	call := ct.calls[serial] or { 
		ct.mutex.runlock()
		return serial 
	}
	ct.mutex.runlock()
	
	ct.finalize_with_body(serial, sequence, msg.body)
	return serial
}

fn (mut ct CallTracker) handle_dbus_error(sequence Sequence, msg &Message) u32 {
	serial := get_reply_serial(msg) or { return 0 }
	ct.mutex.@rlock()
	call := ct.calls[serial] or { 
		ct.mutex.runlock()
		return serial 
	}
	ct.mutex.runlock()
	
	name := get_error_name(msg) or { '' }
	error := DBusError{name: name, body: msg.body}
	ct.finalize_with_error(serial, sequence, error)
	return serial
}

fn (mut ct CallTracker) finalize_with_body(serial u32, sequence Sequence, body []voidptr) {
	ct.mutex.@lock()
	call := ct.calls[serial] or { 
		ct.mutex.unlock()
		return 
	}
	ct.calls.delete(serial)
	ct.mutex.unlock()
	
	mut c := unsafe { call }
	c.body = body
	c.response_sequence = sequence
	c.done()
}

fn (mut ct CallTracker) finalize_with_error(serial u32, sequence Sequence, err DBusError) {
	ct.mutex.@lock()
	call := ct.calls[serial] or { 
		ct.mutex.unlock()
		return 
	}
	ct.calls.delete(serial)
	ct.mutex.unlock()
	
	mut c := unsafe { call }
	c.err = err
	c.response_sequence = sequence
	c.done()
}

// Main connection struct
pub struct Conn {
mut:
	transport     Transport
	ctx           context.Context
	cancel_ctx    ?fn()
	
	close_once    sync.Once
	close_err     ?DBusError
	
	bus_obj       BusObject
	unix_fd       bool
	uuid          string
	
	handler        Handler
	signal_handler SignalHandler
	serial_gen     &SerialGenerator
	
	names         &NameTracker
	calls         &CallTracker
	
	eavesdropped     chan &Message
	eavesdropped_mtx sync.Mutex
}

// ConnectionManager manages shared connections (no globals)
pub struct ConnectionManager {
mut:
	system_conn  ?&Conn
	session_conn ?&Conn
	mutex        sync.Mutex
}

pub fn new_connection_manager() &ConnectionManager {
	return &ConnectionManager{}
}

pub fn (mut cm ConnectionManager) session_bus() !&Conn {
	cm.mutex.@lock()
	defer { cm.mutex.unlock() }
	
	if conn := cm.session_conn {
		if conn.connected() {
			return conn
		}
	}
	
	conn := connect_session_bus()!
	cm.session_conn = conn
	return conn
}

pub fn (mut cm ConnectionManager) system_bus() !&Conn {
	cm.mutex.@lock()
	defer { cm.mutex.unlock() }
	
	if conn := cm.system_conn {
		if conn.connected() {
			return conn
		}
	}
	
	conn := connect_system_bus()!
	cm.system_conn = conn
	return conn
}

pub fn (mut cm ConnectionManager) close_all() {
	cm.mutex.@lock()
	defer { cm.mutex.unlock() }
	
	if mut conn := cm.session_conn {
		conn.close() or {}
		cm.session_conn = none
	}
	
	if mut conn := cm.system_conn {
		conn.close() or {}
		cm.system_conn = none
	}
}

// Factory functions for one-off connections
pub fn new_session_bus() !&Conn {
	return connect_session_bus()
}

pub fn new_system_bus() !&Conn {
	return connect_system_bus()
}

pub fn connect_session_bus(opts ...ConnOption) !&Conn {
	address := get_session_bus_address(true)!
	return connect(address, ...opts)
}

pub fn connect_system_bus(opts ...ConnOption) !&Conn {
	return connect(get_system_bus_platform_address(), ...opts)
}

pub fn connect(address string, opts ...ConnOption) !&Conn {
	mut conn := dial(address, ...opts)!
	// TODO: Implement auth and hello
	// conn.auth()!
	// conn.hello()!
	return conn
}

pub fn dial(address string, opts ...ConnOption) !&Conn {
	transport := get_transport(address)!
	return new_conn(transport, ...opts)
}

fn new_conn(transport Transport, opts ...ConnOption) !&Conn {
	mut conn := &Conn{
		bus_obj : unsafe { nil },
		handler : unsafe { nil },
		signal_handler : unsafe { nil },
		transport: transport
		serial_gen: new_serial_generator()
		names: new_name_tracker()
		calls: new_call_tracker()
		ctx: context.background()
	}
	
	for opt in opts {
		opt(mut conn)!
	}
	
	// Set up the bus object
	conn.bus_obj = &Object{
		conn: conn
		dest: 'org.freedesktop.DBus'
		path: '/org/freedesktop/DBus'
	}
	
	return conn
}

pub fn (mut conn Conn) connected() bool {
	return conn.ctx.err() == none 
}

pub fn (mut conn Conn) close() ? {
	conn.close_once.do_with_param(fn(mut conn Conn) {
		if conn.cancel_ctx != unsafe { nil } {
			conn.cancel_ctx()
		}
		conn.transport.close() or {}
	}, mut conn)
}

pub fn (conn &Conn) object(dest string, path ObjectPath) BusObject {
	return &Object{
		conn: conn
		dest: dest
		path: path
	}
}

pub fn (mut conn Conn) send_with_context(ctx context.Context, msg &Message, ch chan &Call) &Call {
	if ch.cap == 0 {
		panic('dbus: unbuffered channel passed to send')
	}
	
	mut call := &Call{
		done_chan: ch
		ctx: ctx
	}
	
	if msg.msg_type == .type_method_call && (msg.flags & u8(MessageFlag.flag_no_reply_expected)) == 0 {
		call.destination = get_destination(msg) or { '' }
		call.path = get_path(msg) or { ObjectPath('') }
		call.method = get_method_name(msg) or { '' }
		call.args = msg.body
		
		serial := conn.serial_gen.get_serial()
		mut m := unsafe { msg }
		m.serial = serial
		
		conn.calls.track(serial, call)
		conn.send_message(msg) or {
			conn.calls.finalize_with_error(serial, no_sequence, DBusError{name: 'SendError', body: [err.msg()]})
		}
	} else {
		call.err = none
		ch <- call
		conn.send_message(msg) or {}
	}
	
	return call
}

fn (mut conn Conn) send_message(msg &Message) ? {
	return conn.transport.send_message(msg)
}

// Helper functions
fn make_variant(value voidptr) Variant {
	// Simplified - would need proper type detection
	return Variant{
		signature: Signature{'v'}
		value: value
	}
}

fn signature_of(args ...voidptr) Signature {
	// Simplified - would need proper signature generation
	return Signature{''}
}

fn get_session_bus_address(autolaunch bool) ?string {
	if address := os.getenv('DBUS_SESSION_BUS_ADDRESS') {
		if address != '' && address != 'autolaunch:' {
			return address
		}
	}
	
	if !autolaunch {
		return error('dbus: couldn\'t determine address of session bus')
	}
	
	return get_session_bus_platform_address()
}

fn get_system_bus_platform_address() string {
	// Platform-specific implementation needed
	return 'unix:path=/var/run/dbus/system_bus_socket'
}

fn get_session_bus_platform_address() ?string {
	// Platform-specific implementation needed
	return error('not implemented')
}

fn get_transport(address string) ?Transport {
	// Would need to implement transport creation based on address
	return error('transport creation not implemented')
}

// Message helper functions
fn get_reply_serial(msg &Message) !u32 {
	if variant := msg.headers[.field_reply_serial] {
		if variant.value != unsafe { nil } {
			// Assume it's a u32 - in real implementation you'd have proper type info
			return unsafe { *(&u32(variant.value)) }
		}
	}
	return error('no reply serial')
}

fn get_error_name(msg &Message) !string {
	if variant := msg.headers[.field_error_name] {
		if variant.value != unsafe { nil } {
			// Assume it's a string - in real implementation you'd have proper type info
			return unsafe { *(&string(variant.value)) }
		}
	}
	return error('no error name')
}

fn get_destination(msg &Message) !string {
	if variant := msg.headers[.field_destination] {
		if variant.value != unsafe { nil } {
			return unsafe { *(&string(variant.value)) }
		}
	}
	return error('no destination')
}

fn get_path(msg &Message) !ObjectPath {
	if variant := msg.headers[.field_path] {
		if variant.value != unsafe { nil } {
			path_str := unsafe { *(&string(variant.value)) }
			return ObjectPath(path_str)
		}
	}
	return error('no path')
}

fn get_method_name(msg &Message) !string {
	mut iface := ''
	if variant := msg.headers[.field_interface] {
		if variant.value != unsafe { nil } {
			iface = unsafe { *(&string(variant.value)) }
		}
	}
	
	mut member := ''
	if variant := msg.headers[.field_member] {
		if variant.value != unsafe { nil } {
			member = unsafe { *(&string(variant.value)) }
		}
	}
	
	if iface != '' && member != '' {
		return '${iface}.${member}'
	}
	return error('incomplete method name')
}

// ObjectPath validation
pub fn (o ObjectPath) is_valid() bool {
	s := string(o)
	if s.len == 0 {
		return false
	}
	if s[0] != `/` {
		return false
	}
	if s[s.len-1] == `/` && s.len != 1 {
		return false
	}
	if s == '/' {
		return true
	}
	
	parts := s[1..].split('/')
	for part in parts {
		if part.len == 0 {
			return false
		}
		for c in part {
			if !is_member_char(c) {
				return false
			}
		}
	}
	return true
}

fn is_member_char(c u8) bool {
	return (c >= `0` && c <= `9`) || (c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`) || c == `_`
}