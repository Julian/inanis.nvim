describe("is_empty", function()
  it("considers the empty string empty", function()
    assert.is.empty ""
  end)

  it("considers other strings non-empty", function()
    assert.is_not.empty "foo"
  end)

  it("considers empty tables empty", function()
    assert.is.empty {}
  end)

  it("considers other map-like tables non-empty", function()
    assert.is_not.empty { foo = 12 }
  end)

  it("considers other list-like tables non-empty", function()
    assert.is_not.empty { 37 }
  end)

  it("considers nil empty", function()
    assert.is.empty(nil)
  end)
end)
