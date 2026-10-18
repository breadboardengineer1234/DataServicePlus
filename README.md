# DataServicePlus
Simple and lightweight data module built on top of ProfileStore.

Features:
* Specialized networker for buffer compression and batched replication
* Strictly typed for new type solver: autocomplete and cached paths for data template fields
* Simple design and minimal metatable tricks = 3-8x faster performance

# Benchmarks
Benchmarks are conducted in studio with an arbitrary template and the same paths for all modules tested. The average FPS and Kbps are recorded over 10 seconds, and the Kbps is normalized to 60 FPS.

### Read Test (10k reads per frame)
| Module | FPS | Kbps 
|--------------------|----------|----_
| Leif DataServiceTyped | 54.50 | 0.45
| DataServicePlus | 240.00 | 0.10

### Write Test (10k writes per frame)
| Module | FPS | Kbps 
|--------------------|----------|-----------
| Leif DataServiceTyped | 14.95 | 131736.17
| DataServicePlus | 117.42 | 4.09

Note: After running the benchmark for a while DataServiceTyped's memory usage will go through the roof while DataServicePlus's usage remains constant.
**Leif DataServiceTyped:**
![DataServiceTyped](assets/leifStats.png)

**DataServicePlus:**
![DataServicePlus](assets/dataserviceplusStats.png)
