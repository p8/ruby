# frozen_string_literal: false
require 'test/unit'

class TestWeakMap < Test::Unit::TestCase
  def setup
    @wm = ObjectSpace::WeakMap.new
  end

  def test_map
    x = Object.new
    k = "foo"
    @wm[k] = x
    assert_same(x, @wm[k])
    assert_not_same(x, @wm["FOO".downcase])
  end

  def test_aset_const
    x = Object.new
    @wm[true] = x
    assert_same(x, @wm[true])
    @wm[false] = x
    assert_same(x, @wm[false])
    @wm[nil] = x
    assert_same(x, @wm[nil])
    @wm[42] = x
    assert_same(x, @wm[42])
    @wm[:foo] = x
    assert_same(x, @wm[:foo])

    @wm[x] = true
    assert_same(true, @wm[x])
    @wm[x] = false
    assert_same(false, @wm[x])
    @wm[x] = nil
    assert_same(nil, @wm[x])
    @wm[x] = 42
    assert_same(42, @wm[x])
    @wm[x] = :foo
    assert_same(:foo, @wm[x])
  end

  def assert_weak_include(m, k, n = 100)
    if n > 0
      return assert_weak_include(m, k, n-1)
    end
    1.times do
      x = Object.new
      @wm[k] = x
      assert_send([@wm, m, k])
      assert_not_send([@wm, m, "FOO".downcase])
      x = Object.new
    end
  end

  def test_include?
    m = __callee__[/test_(.*)/, 1]
    k = "foo"
    1.times do
      assert_weak_include(m, k)
    end
    GC.start
    pend('TODO: failure introduced from 837fd5e494731d7d44786f29e7d6e8c27029806f')
    assert_not_send([@wm, m, k])
  end
  alias test_member? test_include?
  alias test_key? test_include?

  def test_inspect
    x = Object.new
    k = BasicObject.new
    @wm[k] = x
    assert_match(/\A\#<#{@wm.class.name}:[^:]+:\s\#<BasicObject:[^:]*>\s=>\s\#<Object:[^:]*>>\z/,
                 @wm.inspect)
  end

  def test_inspect_garbage
    1000.times do |i|
      @wm[i] = Object.new
      @wm.inspect
    end
    assert_match(/\A\#<#{@wm.class.name}:[^:]++:(?:\s\d+\s=>\s\#<(?:Object|collected):[^:<>]*+>(?:,|>\z))+/,
                 @wm.inspect)
  end

  def test_delete
    k1 = "foo"
    x1 = Object.new
    @wm[k1] = x1
    assert_equal x1, @wm[k1]
    assert_equal x1, @wm.delete(k1)
    assert_nil @wm[k1]
    assert_nil @wm.delete(k1)

    fallback =  @wm.delete(k1) do |key|
      assert_equal k1, key
      42
    end
    assert_equal 42, fallback
  end

  def test_each
    m = __callee__[/test_(.*)/, 1]
    x1 = Object.new
    k1 = "foo"
    @wm[k1] = x1
    x2 = Object.new
    k2 = "bar"
    @wm[k2] = x2
    n = 0
    @wm.__send__(m) do |k, v|
      assert_match(/\A(?:foo|bar)\z/, k)
      case k
      when /foo/
        assert_same(k1, k)
        assert_same(x1, v)
      when /bar/
        assert_same(k2, k)
        assert_same(x2, v)
      end
      n += 1
    end
    assert_equal(2, n)
  end

  def test_each_key
    x1 = Object.new
    k1 = "foo"
    @wm[k1] = x1
    x2 = Object.new
    k2 = "bar"
    @wm[k2] = x2
    n = 0
    @wm.each_key do |k|
      assert_match(/\A(?:foo|bar)\z/, k)
      case k
      when /foo/
        assert_same(k1, k)
      when /bar/
        assert_same(k2, k)
      end
      n += 1
    end
    assert_equal(2, n)
  end

  def test_each_value
    x1 = "foo"
    k1 = Object.new
    @wm[k1] = x1
    x2 = "bar"
    k2 = Object.new
    @wm[k2] = x2
    n = 0
    @wm.each_value do |v|
      assert_match(/\A(?:foo|bar)\z/, v)
      case v
      when /foo/
        assert_same(x1, v)
      when /bar/
        assert_same(x2, v)
      end
      n += 1
    end
    assert_equal(2, n)
  end

  def test_size
    m = __callee__[/test_(.*)/, 1]
    assert_equal(0, @wm.__send__(m))
    x1 = "foo"
    k1 = Object.new
    @wm[k1] = x1
    assert_equal(1, @wm.__send__(m))
    x2 = "bar"
    k2 = Object.new
    @wm[k2] = x2
    assert_equal(2, @wm.__send__(m))
  end
  alias test_length test_size

  def test_frozen_object
    o = Object.new.freeze
    assert_nothing_raised(FrozenError) {@wm[o] = 'foo'}
    assert_nothing_raised(FrozenError) {@wm['foo'] = o}
  end

  def test_no_memory_leak
    assert_no_memory_leak([], '', "#{<<~"begin;"}\n#{<<~'end;'}", "[Bug #19398]", rss: true, limit: 1.5, timeout: 60)
    begin;
      1_000_000.times do
        ObjectSpace::WeakMap.new
      end
    end;
  end

  def test_compaction
    omit "compaction is not supported on this platform" unless GC.respond_to?(:compact)

    # [Bug #19529]
    obj = Object.new
    100.times do |i|
      GC.compact
      @wm[i] = obj
    end

    assert_separately([], <<-'end;')
      wm = ObjectSpace::WeakMap.new
      obj = Object.new
      100.times do
        wm[Object.new] = obj
        GC.start
      end
      GC.compact
    end;

    assert_separately(%w(-robjspace), <<-'end;')
      wm = ObjectSpace::WeakMap.new
      key = Object.new
      val = Object.new
      wm[key] = val

      GC.verify_compaction_references(expand_heap: true, toward: :empty)

      assert_equal(val, wm[key])
    end;
  end

  def test_replaced_values_bug_19531
    a = "A".dup
    b = "B".dup

    @wm[1] = a
    @wm[1] = a
    @wm[1] = a

    @wm[1] = b
    assert_equal b, @wm[1]

    a = nil
    GC.start

    assert_equal b, @wm[1]
  end
end
