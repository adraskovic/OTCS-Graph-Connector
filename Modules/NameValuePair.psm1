class NameValuePair {                                                 
    [object]$name
    [object]$value

    NameValuePair(
        [object]$name,
        [object]$value)
    {
        $this.name = $name
        $this.value = $value
    }
}