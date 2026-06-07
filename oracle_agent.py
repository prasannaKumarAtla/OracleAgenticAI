import os
import asyncio
import operator
from typing import Annotated, TypedDict, List, Dict
from pydantic import BaseModel, Field
from dotenv import load_dotenv

# --- MCP Imports ---
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

# --- LangChain Imports ---
from langchain_ollama import ChatOllama
from langchain_core.tools import StructuredTool
from langchain_core.messages import SystemMessage, HumanMessage
from langgraph.graph import StateGraph, END

load_dotenv()

# Initialize LLM (Ensure Ollama is running Gemma4)
llm_sandbox = ChatOllama(model="gemma4", temperature=0)
orchestrator_model = llm_sandbox
domain_model = llm_sandbox

# 1. Define Structured Output Schema for Routing
class RoutingDecision(BaseModel):
    target_domains: List[str] = Field(
        description="List of Oracle business domains required for the query (e.g., 'HCM', 'SCM', 'FIN', 'CRM')."
    )

# 2. Define the Shared State
class GraphState(TypedDict):
    user_query: str
    target_domains: List[str]
    sql_snippets: Annotated[List[Dict[str, str]], operator.add]

# ---------------------------------------------------------
# Async Main Wrapper for MCP Connection
# ---------------------------------------------------------
async def run_agent_workflow(user_input: str):
    
    # Configure your MCP Server Command
    server_params = StdioServerParameters(
        command="docker", 
        args=[
            "run", 
            "-i",     # CRITICAL: Keeps STDIN open for the MCP communication
            "--rm",   # Cleans up the container when the connection closes
            "ghcr.io/oracle/mcp/oracle-db-doc:latest"
        ] 
    )

    print("Connecting to Oracle MCP Server...")
    
    # Establish the MCP Connection
    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            print("Connected successfully!")
            
            # Fetch tools exposed by the Oracle MCP server
            mcp_tools_response = await session.list_tools()
            
            # Convert MCP Tools to LangChain Tools
            langchain_tools = []
            for mcp_tool in mcp_tools_response.tools:
                
                async def mcp_tool_executor(*args, tool_name=mcp_tool.name, **kwargs):
                    result = await session.call_tool(tool_name, arguments=kwargs)
                    return "\n".join(content.text for content in result.content if content.type == "text")

                langchain_tools.append(
                    StructuredTool.from_function(
                        coroutine=mcp_tool_executor,
                        name=mcp_tool.name,
                        description=mcp_tool.description,
                    )
                )
                
            print(f"Loaded {len(langchain_tools)} tools from MCP server.")

            # ---------------------------------------------------------
            # 3. Define Async LangGraph Nodes
            # ---------------------------------------------------------
            async def orchestrator_node(state: GraphState):
                query = state.get("user_query")
                print(f"--- ORCHESTRATOR: Analyzing query ---")
                
                sys_msg = SystemMessage(content="""
                You are an Oracle SQL Routing Orchestrator. 
                Analyze the user's request and determine which business domains (HCM, SCM, FIN, CRM, etc.) 
                are required to fulfill the request. Return ONLY the extracted domains.
                """)
                
                # Enforce structured Pydantic output to eliminate routing hallucinations
                structured_llm = orchestrator_model.with_structured_output(RoutingDecision)
                response = await structured_llm.ainvoke([sys_msg, HumanMessage(content=query)])
                
                chosen_domains = response.target_domains
                print(f"--- ORCHESTRATOR: Routed to {chosen_domains} ---")
                return {"target_domains": chosen_domains}

            async def domain_agent_node(state: GraphState):
                query = state.get("user_query")
                domains = state.get("target_domains", [])
                snippets = []
                
                # Bind the MCP tools to the domain agent so it can research Oracle documentation
                agent_with_tools = domain_model.bind_tools(langchain_tools)
                
                for domain in domains:
                    print(f"--- DOMAIN AGENT: Generating SQL for {domain} ---")
                    
                    sys_msg = SystemMessage(content=f"""
                    You are an expert Oracle SQL developer for the {domain} business domain.
                    Use your available tools to research Oracle 19c/23c syntax if necessary.
                    
                    CRITICAL INSTRUCTIONS:
                    1. Write a valid Oracle SQL query to answer the user's request.
                    2. ONLY output the SQL code formatted neatly in a markdown block.
                    3. Ensure your query strictly utilizes tables native to the {domain} domain.
                    """)
                    
                    response = await agent_with_tools.ainvoke([sys_msg, HumanMessage(content=query)])
                    
                    # Extract the formatted SQL string
                    generated_sql = response.content.strip()
                    snippets.append({domain: generated_sql})
                    
                return {"sql_snippets": snippets}

            # ---------------------------------------------------------
            # 4. Assemble and Run the Graph
            # ---------------------------------------------------------
            workflow = StateGraph(GraphState)
            workflow.add_node("orchestrator", orchestrator_node)
            workflow.add_node("domain_agent", domain_agent_node)
            
            workflow.set_entry_point("orchestrator")
            workflow.add_edge("orchestrator", "domain_agent")
            workflow.add_edge("domain_agent", END)
            
            app = workflow.compile()
            
            initial_state = {
                "user_query": user_input,
                "target_domains": [],
                "sql_snippets": []
            }

            print("\n--- Running Agentic Workflow ---")
            async for output in app.astream(initial_state):
                for node_name, state_update in output.items():
                    if node_name == "domain_agent":
                        for snippet_dict in state_update.get("sql_snippets", []):
                            for domain, sql in snippet_dict.items():
                                print(f"\n[{domain} Final Output]:\n{sql}\n")

# Execute
if __name__ == "__main__":
    test_query = """Using Oracle Fusion Cloud schema, write a SQL query that retrieves 
    the first and last names of all active employees who have raised a 
    Purchase Order for items in the 'IT Equipment' category, alongside 
    the total invoice amount that has been fully paid against those specific purchase orders."""
    
    asyncio.run(run_agent_workflow(test_query))
